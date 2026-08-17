" Read by every nvim on the lab, before ~/.config/nvim.  A checkout that brings
" its own configuration owns the editor outright: drop this directory out of
" packpath so the lab's plugins do not load underneath it, and stand down.
let s:dlab = expand('<sfile>:p:h')

if filereadable(stdpath('config') . '/init.lua') || filereadable(stdpath('config') . '/init.vim')
  let &packpath = join(filter(split(&packpath, ','), 'v:val !=# s:dlab'), ',')
  finish
endif

lua require('dlab')
