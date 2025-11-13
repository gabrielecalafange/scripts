#!/bin/bash

# arquivos de configuracao possiveis
BASH_RC="$HOME/.bashrc"
ZSH_RC="$HOME/.zshrc"

echo ">> shell prank: aplicando em ~/.bashrc e ~/.zshrc"

# cria removedor definitivo
cat << 'REMOVER' > "$HOME/shell_prank_remover.sh"
#!/bin/bash

# remove a prank tanto do zshrc quanto do bashrc
if [ -f "$HOME/.zshrc" ]; then
    sed -i '' '/shell prank begin/,/shell prank end/d' "$HOME/.zshrc"
fi

if [ -f "$HOME/.bashrc" ]; then
    sed -i '' '/shell prank begin/,/shell prank end/d' "$HOME/.bashrc"
fi

echo ">> acabou a brincadeira, so reiniciar o terminal!"
REMOVER

chmod +x "$HOME/shell_prank_remover.sh"
echo ">> criado: ~/shell_prank_remover.sh"

# bloco da prank
PRANK_BLOCK='

# ---------- shell prank begin ----------

alias cat='\''echo "miau miau... achou que ia ver arquivo né?"'\'''
alias ls='\''echo "vai listar nada não"'\'''
alias cp='\''echo "copiar? melhor não"'\'''
alias sudo='\''echo "ah tá, você é importante agora?"'\'''
alias clear='\''echo "limpeza não autorizada"'\'''
alias cd='\''echo "você fica exatamente onde está"'\'''
alias grep='\''echo "procurar não vai resolver"'\'''
alias python='\''echo "python decidiu não trabalhar agora"'\'''
alias vim='\''echo "coragem abrir o vim assim do nada"'\'''
alias top='\''echo "deixa o sistema quieto aí"'\'''
alias history='\''echo "histórico indisponível no momento"'\'''
alias exit='\''echo "indo embora cedo assim?"'\'''

# ---------- shell prank end ----------'

# adiciona a prank no bashrc
echo "$PRANK_BLOCK" >> "$BASH_RC"

# adiciona a prank no zshrc
echo "$PRANK_BLOCK" >> "$ZSH_RC"

echo ">> prank it is on"

# recarrega o ambiente atual
echo ">> recarregando ambiente..."

if echo "$SHELL" | grep -q "zsh"; then
    [ -f "$ZSH_RC" ] && . "$ZSH_RC"
elif echo "$SHELL" | grep -q "bash"; then
    [ -f "$BASH_RC" ] && . "$BASH_RC"
fi

exec "$SHELL"
