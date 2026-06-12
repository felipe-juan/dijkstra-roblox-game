# IFBA com Dijkstra – Aprenda Grafos Jogando! 🧠🎮

> **⚠️ Aviso Importante:** Este código foi gerado integralmente por Inteligência Artificial.  
> Nenhum ser humano escreveu diretamente as linhas deste projeto; toda a lógica, interface e mecânicas foram sintetizadas por IA. Apenas as ideias de funcionalidades, teste e execução foram feitas por mim.

---

Um jogo educativo no Roblox para aprender o **Algoritmo de Dijkstra** de forma interativa.  
Explore um grafo com nós e arestas, escolha caminhos, compare seu custo com o caminho ótimo e acumule pontos – tudo em uma atmosfera neon e vibrante!

---

## 🧩 Funcionalidades

- ✅ **Modos de jogo**  
  - **Padrão:** mapa fixo, apenas os pesos das arestas mudam a cada rodada.  
  - **Aleatório:** conexões, nó inicial e destino sorteados – cada partida é única.

- ⏱️ **Temporizador por rodada**  
  Tempo base + bônus por aresta do caminho ideal. Cor muda de verde → amarelo → vermelho, com pulsos nos últimos segundos.

- 🗺️ **Minimapa interativo**  
  Mostra nós, arestas, caminho percorrido e ótimo. Possui rotação configurável (edite `MINIMAP_ROTATION` no código) e botão de ocultar.

- 📜 **Histórico de conexões**  
  Painel retrátil exibe cada movimento (✔ correto / ✘ errado) com custo e cores neon.

- 🏆 **Sistema de pontuação**  
  Cartões com custo, ideal, penalidade, rodada e total – código de cores e acentos luminosos.

- 🎨 **Interface moderna**  
  Tipografia Gotham, gradientes, bordas neon, animações de entrada, efeitos de hover em todos os botões e som de clique.

- 🔍 **Modo Exploração Livre**  
  Navegue pelo mapa sem objetivos, pontuação ou temporizador. Ative/desative o **Modo Destruição** para remover partes do cenário (efeito visual de pulso quando ativo).

- 📷 **Vista Topo (Top‑Down)**  
  Ative com a tecla `V` ou botão na tela. Zoom com scroll do mouse. Nomes dos nós flutuantes.

- 🔊 **Feedback audiovisual**  
  Partículas, textos flutuantes, pulsos nos nós e sons distintos para acerto, erro, missão completa e falha.

---

## 🚀 Como jogar

1. **Inicie** o jogo no Roblox Studio ou em um servidor.
2. No menu inicial, escolha o modo (`Padrão` ou `Aleatório`) e clique em **Iniciar Jogo** ou **Exploração Livre**.
3. Siga as instruções: *“Chegue até o nó X”*.  
   - Os vizinhos permitidos ficam destacados com contorno pulsante.
   - Aproxime‑se e pressione **E** ou toque no nó para se mover.
4. O custo acumulado é exibido no painel de estatísticas.
5. Ao chegar ao destino, veja se seu caminho foi ótimo e a pontuação da rodada.
6. Clique em **Jogar Novamente** para continuar acumulando pontos.

---

## ⚙️ Configuração rápida (para desenvolvedores)

- O arquivo principal é `DijkstraClient.lua` (coloque em `StarterPlayerScripts`).
- Os remotos estão em `ReplicatedStorage > DijkstraRemotes`.
- Os nós do grafo devem estar dentro de `Workspace > Nodes` (partes ou modelos com nomes únicos).
- Para alterar a rotação do minimapa, edite a variável `MINIMAP_ROTATION` no início do script (linha aproximada após a tabela `COL`).

---

## 🛠️ Estrutura do código (resumo)

| Módulo / Seção | Descrição |
|----------------|-----------|
| **Remotes** | Comunicação cliente‑servidor (seleção de nó, reset, modo, destruição). |
| **Sons e efeitos** | Sons de UI, ambiente, feedback e partículas 3D. |
| **UI principal** | Menu inicial, painel de estatísticas, card de missão, timer, minimapa, painel de histórico, sobreposições de sucesso/falha. |
| **Modo livre** | Botões flutuantes para retornar ao menu e ativar destruição. |
| **Câmera Top‑Down** | Ativada por tecla `V`, com zoom e labels 3D. |
| **Desenho 3D** | Arestas com cores baseadas no estado (não visitada, correta, errada, ótima). |
| **Minimapa** | Renderização 2D no canto superior direito (com rotação opcional). |
| **GameState handler** | Atualiza toda a UI a cada evento do servidor. |

---

## 🧪 Tecnologias utilizadas

- Roblox Lua (Luau)
- Serviços: `Players`, `ReplicatedStorage`, `RunService`, `TweenService`, `UserInputService`, `Workspace`
- UI: `ScreenGui`, `UIScale`, `UIGradient`, `UIStroke`, `ScrollingFrame`
- Áudio: sons customizados do Roblox (IDs fornecidos)

---

## 📚 Propósito educacional

Este jogo foi criado para auxiliar no ensino do **algoritmo de Dijkstra**, mostrando na prática:
- a diferença entre um caminho qualquer e o caminho de custo mínimo;
- a penalidade por desvios;
- a visualização do grafo e dos custos em tempo real.

Ideal para aulas de **Teoria dos Grafos**, **Estruturas de Dados** ou **Matemática Discreta** no IFBA e outras instituições.

---

## 📝 Licença

Este projeto é disponibilizado **sem garantias**, para fins educacionais e de demonstração.  
Sinta‑se livre para estudar, modificar e compartilhar, dando os devidos créditos ao IFBA e ao conceito original.
