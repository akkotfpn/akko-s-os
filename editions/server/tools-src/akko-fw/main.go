// akko-fw — firewall do Akko's OS
//
// Monta uma tabela nftables "inet akkos" a partir de arquivos de configuração,
// falando direto com o kernel via netlink (sem depender da ferramenta `nft`).
//
// Política: entrada e encaminhamento BLOQUEADOS por padrão; saída liberada.
// Sempre liberado na entrada: loopback, conexões já estabelecidas, ICMP/ICMPv6
// e respostas de DHCP. O resto só se estiver listado:
//
//	/etc/akko/firewall.conf      regras do sistema (SSH)
//	/data/etc/firewall.conf      suas regras
//	/data/apps/*/app.conf        linhas "port=8080" ou "port=53/udp" dos apps
//
// Formato das regras:  allow tcp 22   |   allow udp 53   |   allow tcp 8000-8010
//
// Uso: akko-fw apply | show | off
package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/google/nftables"
	"github.com/google/nftables/binaryutil"
	"github.com/google/nftables/expr"
	"golang.org/x/sys/unix"
)

const tableName = "akkos"

type portRule struct {
	proto    string // tcp | udp
	from, to uint16
	source   string
}

func (r portRule) String() string {
	p := strconv.Itoa(int(r.from))
	if r.to != r.from {
		p += "-" + strconv.Itoa(int(r.to))
	}
	return fmt.Sprintf("%s %s", r.proto, p)
}

func parsePorts(s string) (uint16, uint16, error) {
	a, b, isRange := strings.Cut(s, "-")
	from, err := strconv.ParseUint(a, 10, 16)
	if err != nil || from == 0 {
		return 0, 0, fmt.Errorf("porta inválida: %q", s)
	}
	to := from
	if isRange {
		to, err = strconv.ParseUint(b, 10, 16)
		if err != nil || to < from {
			return 0, 0, fmt.Errorf("faixa inválida: %q", s)
		}
	}
	return uint16(from), uint16(to), nil
}

func loadRules() ([]portRule, []string) {
	var rules []portRule
	var warnings []string

	readConf := func(path string) {
		f, err := os.Open(path)
		if err != nil {
			return
		}
		defer f.Close()
		sc := bufio.NewScanner(f)
		for n := 1; sc.Scan(); n++ {
			line := strings.TrimSpace(sc.Text())
			if i := strings.IndexByte(line, '#'); i >= 0 {
				line = strings.TrimSpace(line[:i])
			}
			if line == "" {
				continue
			}
			f := strings.Fields(line)
			if len(f) != 3 || f[0] != "allow" || (f[1] != "tcp" && f[1] != "udp") {
				warnings = append(warnings, fmt.Sprintf("%s:%d: ignorado: %q", path, n, line))
				continue
			}
			from, to, err := parsePorts(f[2])
			if err != nil {
				warnings = append(warnings, fmt.Sprintf("%s:%d: %v", path, n, err))
				continue
			}
			rules = append(rules, portRule{f[1], from, to, path})
		}
	}

	readConf("/etc/akko/firewall.conf")
	readConf("/data/etc/firewall.conf")

	apps, _ := filepath.Glob("/data/apps/*/app.conf")
	sort.Strings(apps)
	for _, conf := range apps {
		data, err := os.ReadFile(conf)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
			if !ok || strings.TrimSpace(k) != "port" {
				continue
			}
			for _, item := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' }) {
				proto := "tcp"
				if p, pr, ok := strings.Cut(item, "/"); ok {
					item, proto = p, pr
				}
				from, to, err := parsePorts(item)
				if err != nil || (proto != "tcp" && proto != "udp") {
					warnings = append(warnings, fmt.Sprintf("%s: porta ignorada: %q", conf, item))
					continue
				}
				rules = append(rules, portRule{proto, from, to, conf})
			}
		}
	}
	return rules, warnings
}

// ---- construção das expressões nftables ----

func ctStateAccept(states uint32) []expr.Any {
	return []expr.Any{
		&expr.Ct{Register: 1, Key: expr.CtKeySTATE},
		&expr.Bitwise{SourceRegister: 1, DestRegister: 1, Len: 4,
			Mask: binaryutil.NativeEndian.PutUint32(states), Xor: binaryutil.NativeEndian.PutUint32(0)},
		&expr.Cmp{Op: expr.CmpOpNeq, Register: 1, Data: binaryutil.NativeEndian.PutUint32(0)},
		&expr.Verdict{Kind: expr.VerdictAccept},
	}
}

func ctStateDrop(states uint32) []expr.Any {
	e := ctStateAccept(states)
	e[3] = &expr.Verdict{Kind: expr.VerdictDrop}
	return e
}

func l4proto(p byte) []expr.Any {
	return []expr.Any{
		&expr.Meta{Key: expr.MetaKeyL4PROTO, Register: 1},
		&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte{p}},
	}
}

func portAccept(proto byte, from, to uint16) []expr.Any {
	e := l4proto(proto)
	e = append(e, &expr.Payload{DestRegister: 1, Base: expr.PayloadBaseTransportHeader, Offset: 2, Len: 2})
	if from == to {
		e = append(e, &expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: binaryutil.BigEndian.PutUint16(from)})
	} else {
		e = append(e,
			&expr.Cmp{Op: expr.CmpOpGte, Register: 1, Data: binaryutil.BigEndian.PutUint16(from)},
			&expr.Cmp{Op: expr.CmpOpLte, Register: 1, Data: binaryutil.BigEndian.PutUint16(to)})
	}
	return append(e, &expr.Verdict{Kind: expr.VerdictAccept})
}

func apply() error {
	rules, warnings := loadRules()
	for _, w := range warnings {
		fmt.Fprintln(os.Stderr, "aviso:", w)
	}

	c, err := nftables.New()
	if err != nil {
		return err
	}
	// apaga a tabela antiga (se existir) e recria do zero, numa transação só
	t := &nftables.Table{Family: nftables.TableFamilyINet, Name: tableName}
	if tables, err := c.ListTablesOfFamily(nftables.TableFamilyINet); err == nil {
		for _, old := range tables {
			if old.Name == tableName {
				c.DelTable(old)
			}
		}
	}
	c.AddTable(t)

	drop := nftables.ChainPolicyDrop
	accept := nftables.ChainPolicyAccept
	input := c.AddChain(&nftables.Chain{Name: "input", Table: t, Type: nftables.ChainTypeFilter,
		Hooknum: nftables.ChainHookInput, Priority: nftables.ChainPriorityFilter, Policy: &drop})
	c.AddChain(&nftables.Chain{Name: "forward", Table: t, Type: nftables.ChainTypeFilter,
		Hooknum: nftables.ChainHookForward, Priority: nftables.ChainPriorityFilter, Policy: &drop})
	c.AddChain(&nftables.Chain{Name: "output", Table: t, Type: nftables.ChainTypeFilter,
		Hooknum: nftables.ChainHookOutput, Priority: nftables.ChainPriorityFilter, Policy: &accept})

	add := func(e []expr.Any) { c.AddRule(&nftables.Rule{Table: t, Chain: input, Exprs: e}) }

	// loopback
	add([]expr.Any{
		&expr.Meta{Key: expr.MetaKeyIIFNAME, Register: 1},
		&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte("lo\x00")},
		&expr.Verdict{Kind: expr.VerdictAccept},
	})
	add(ctStateAccept(expr.CtStateBitESTABLISHED | expr.CtStateBitRELATED))
	add(ctStateDrop(expr.CtStateBitINVALID))
	add(append(l4proto(unix.IPPROTO_ICMP), &expr.Verdict{Kind: expr.VerdictAccept}))
	add(append(l4proto(unix.IPPROTO_ICMPV6), &expr.Verdict{Kind: expr.VerdictAccept}))
	add(portAccept(unix.IPPROTO_UDP, 68, 68)) // respostas DHCP

	seen := map[string]bool{}
	for _, r := range rules {
		if seen[r.String()] {
			continue
		}
		seen[r.String()] = true
		p := byte(unix.IPPROTO_TCP)
		if r.proto == "udp" {
			p = unix.IPPROTO_UDP
		}
		add(portAccept(p, r.from, r.to))
	}

	if err := c.Flush(); err != nil {
		return fmt.Errorf("aplicando regras: %w", err)
	}
	var open []string
	for k := range seen {
		open = append(open, k)
	}
	sort.Strings(open)
	fmt.Printf("firewall ativo: entrada bloqueada, liberado: %s\n", strings.Join(open, ", "))
	return nil
}

func show() error {
	c, err := nftables.New()
	if err != nil {
		return err
	}
	tables, err := c.ListTablesOfFamily(nftables.TableFamilyINet)
	if err != nil {
		return err
	}
	active := false
	for _, t := range tables {
		if t.Name == tableName {
			active = true
			rules, _ := c.GetRules(t, &nftables.Chain{Name: "input", Table: t})
			fmt.Printf("firewall: ATIVO (%d regras de entrada)\n", len(rules))
		}
	}
	if !active {
		fmt.Println("firewall: DESLIGADO (tudo liberado)")
		return nil
	}
	rules, _ := loadRules()
	fmt.Println("sempre liberado: loopback, conexões estabelecidas, ICMP, DHCP")
	for _, r := range rules {
		fmt.Printf("  allow %-12s (%s)\n", r.String(), r.source)
	}
	return nil
}

func off() error {
	c, err := nftables.New()
	if err != nil {
		return err
	}
	tables, err := c.ListTablesOfFamily(nftables.TableFamilyINet)
	if err != nil {
		return err
	}
	for _, t := range tables {
		if t.Name == tableName {
			c.DelTable(t)
		}
	}
	if err := c.Flush(); err != nil {
		return err
	}
	fmt.Println("firewall desligado: tudo liberado (cuidado!)")
	return nil
}

func main() {
	cmd := "show"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	var err error
	switch cmd {
	case "apply", "reload":
		err = apply()
	case "show", "status":
		err = show()
	case "off":
		err = off()
	default:
		fmt.Fprintln(os.Stderr, "uso: akko-fw apply | show | off")
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "akko-fw:", err)
		os.Exit(1)
	}
}
