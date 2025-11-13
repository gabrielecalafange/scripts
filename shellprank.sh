#!/bin/bash

# detecta qual rc usar
if [ -n "$ZSH_VERSION" ]; then
    RC_FILE="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ]; then
    RC_FILE="$HOME/.bashrc"
else
    if echo "$SHELL" | grep -q "zsh"; then
        RC_FILE="$HOME/.zshrc"
    else
        RC_FILE="$HOME/.bashrc"
    fi
fi

echo ">> shell prank: $RC_FILE"

# cria removedor definitivo
cat << 'REMOVER' > "$HOME/shell_prank_remover.sh"
#!/bin/bash

# remove a prank tanto do zshrc quanto do bashrc
if [ -f "$HOME/.zshrc" ]; then
    sed -i '' '/SHELL PRANK BEGIN/,/SHELL PRANK END/d' "$HOME/.zshrc"
fi

if [ -f "$HOME/.bashrc" ]; then
    sed -i '' '/SHELL PRANK BEGIN/,/SHELL PRANK END/d' "$HOME/.bashrc"
fi

echo ">> acabou a brincadeira, so reiniciar o terminal!"
REMOVER

chmod +x "$HOME/shell_prank_remover.sh"
echo ">> criado: ~/shell_prank_remover.sh"

# adiciona a prank
cat << 'EOF' >> "$RC_FILE"

# ---------- shell prank begin ----------

alias cat='echo "miau miau... achou que ia ver arquivo né?"'
alias ls='echo "vai listar nada não"'
alias cp='echo "copiar? melhor não"'
alias sudo='echo "ah tá, você é importante agora?"'
alias clear='echo "limpeza não autorizada"'
alias cd='echo "você fica exatamente onde está"'
alias grep='echo "procurar não vai resolver"'
alias python='echo "python decidiu não trabalhar agora"'
alias vim='echo "coragem abrir o vim assim do nada"'
alias top='echo "deixa o sistema quieto aí"'
alias history='echo "histórico indisponível no momento"'
alias exit='echo "indo embora cedo assim?"'

# ---------- shell prank end ----------

EOF

echo ">> prank it is on"

# reinicia o ambiente automaticamente
echo ">> recarregando ambiente..."
source "$RC_FILE"
exec $SHELL

