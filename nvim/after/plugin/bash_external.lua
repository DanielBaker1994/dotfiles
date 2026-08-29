-- Eagerly load every external bash command module so their async prefetch
-- runs once at startup and is cached before any command uses it.
--
-- Keep the bash side of these in sync: ~/.dotfiles/bash/external.sh.
require('bash_external.cd_targets')
require('bash_external.external_paths')
require('bash_external.jira')
require('bash_external.asset_pictures_dir')
-- defs drives the action commands (build_and_open_pdf etc.); preloading
-- dumps the fast-run defs file at startup so actions never pay login-shell cost.
require('bash_external.defs').preload()