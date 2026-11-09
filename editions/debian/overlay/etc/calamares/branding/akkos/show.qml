/* Akko's OS — apresentação exibida enquanto o sistema é instalado */
import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation {
    id: presentation

    function nextSlide() { presentation.goToNextSlide(); }

    Timer {
        id: avancar
        interval: 7000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: nextSlide()
    }

    Repeater {
        model: [
            ["Bem-vindo ao Akko's OS", "Leve, bonito e seu. Enquanto copiamos o sistema, conheça o que vem pronto."],
            ["Arquivos como no Windows", "Este Computador, unidades C:, D:… e Acesso rápido. Nova pasta? Botão Novo ▸ Pasta."],
            ["Programas e jogos do Windows", "Dois cliques num .exe: escolha Aplicativo (Wine) ou Jogo (Proton, o mesmo do Steam)."],
            ["Gerenciador de Tarefas", "Ctrl+Shift+Esc mostra processos, CPU, memória, disco, rede e placa de vídeo."],
            ["Seguro desde o início", "Firewall ligado, navegador e programas Windows em sandbox, AppArmor ativo."]
        ]
        Slide {
            Rectangle { anchors.fill: parent; color: "#120A0D" }
            Image {
                id: logo
                source: "akkos-logo.png"
                width: 96; height: 96
                fillMode: Image.PreserveAspectFit
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: parent.height * 0.12
            }
            Text {
                id: titulo
                text: modelData[0]
                color: "#FFFFFF"
                font.pixelSize: 26
                font.bold: true
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: logo.bottom
                anchors.topMargin: 24
            }
            Text {
                text: modelData[1]
                color: "#D9C2C7"
                font.pixelSize: 16
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                width: parent.width * 0.75
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: titulo.bottom
                anchors.topMargin: 16
            }
        }
    }

    function onActivate() { avancar.running = true; }
    function onLeave() { avancar.running = false; }
}
