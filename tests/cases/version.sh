# --- version --------------------------------------------------------------------
# Answerable before anything is installed: every other subcommand needs a config,
# and "which version is this?" is exactly what you ask of a copy you just cloned.
echo "version:"
new_sandbox
ver=$(agent --version)
expect_eq "--version reports the version" "$ver" "guise 0.7.3"
expect_eq "the subcommand form agrees" "$(agent version)" "$ver"
expect_eq "and the short flag" "$(agent -v)" "$ver"
expect_eq "the usage banner carries the same one" \
  "$(agent help | head -1 | cut -d' ' -f1-2)" "$ver"
expect "no config was needed to answer" test ! -e "$HOME/.config/guise/config"

