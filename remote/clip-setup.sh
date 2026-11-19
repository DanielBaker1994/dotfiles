#!/bin/sh
# OSC 52 clipboard on a remote box: yanks in vim land in the Mac clipboard.
# Run from the Mac:   ssh HOST 'sh -s' < ~/.dotfiles/remote/clip-setup.sh
# Or paste this file into the remote shell. Safe to run twice.
# Test on the box:    echo hello | ~/bin/clip   then Cmd-V on the Mac.
# Needs vim (vim-tiny is fine), not true vi. Copies whole lines only.

mkdir -p ~/bin
cat > ~/bin/clip <<'EOF'
#!/bin/sh
printf '\033]52;c;%s\a' "$(base64 | tr -d '\n')" > /dev/tty
EOF
chmod +x ~/bin/clip

grep -q '~/bin/clip' ~/.vimrc 2>/dev/null || cat >> ~/.vimrc <<'EOF'
nnoremap yy  yy:silent '[,']w !~/bin/clip<CR>:redraw!<CR>
nnoremap Y   yy:silent '[,']w !~/bin/clip<CR>:redraw!<CR>
nnoremap yip yip:silent '[,']w !~/bin/clip<CR>:redraw!<CR>
nnoremap yap yap:silent '[,']w !~/bin/clip<CR>:redraw!<CR>
vnoremap y   y:silent '[,']w !~/bin/clip<CR>:redraw!<CR>
nnoremap gy  :silent '[,']w !~/bin/clip<CR>:redraw!<CR>
EOF
