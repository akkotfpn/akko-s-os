module akkos/akko-fw

go 1.24

require (
	github.com/google/nftables v0.3.0
	golang.org/x/sys v0.33.0
)

require (
	github.com/google/go-cmp v0.6.0 // indirect
	github.com/mdlayher/netlink v1.7.3-0.20250113171957-fbb4dce95f42 // indirect
	github.com/mdlayher/socket v0.5.0 // indirect
	golang.org/x/net v0.33.0 // indirect
	golang.org/x/sync v0.6.0 // indirect
)

replace (
	golang.org/x/net => github.com/golang/net v0.40.0
	golang.org/x/sync => github.com/golang/sync v0.14.0
	golang.org/x/sys => github.com/golang/sys v0.33.0
)
