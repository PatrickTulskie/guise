# A disposable machine to run guise against: the same Linux tooling CI uses,
# and a $HOME that setup, rename and uninstall can wreck for free.
FROM debian:bookworm-slim

# git, openssl, jq and ssh-keygen are what guise itself shells out to; perl
# carries shasum, which the suite hashes artifacts with; zsh makes the shell
# hook exercisable instead of skipped. op, curl and gh stay stubbed.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      jq \
      less \
      openssh-client \
      openssl \
      perl \
      zsh \
  && rm -rf /var/lib/apt/lists/*

COPY docker/entrypoint.sh /usr/local/bin/guise-sandbox
RUN chmod 755 /usr/local/bin/guise-sandbox && useradd --create-home agent

USER agent
WORKDIR /work

# The human this machine belongs to, so the commit hook's co-author fallback
# has something to fall back to.
RUN git config --global user.name "Human" \
 && git config --global user.email "human@example.com" \
 && git config --global init.defaultBranch main

ENTRYPOINT ["/usr/local/bin/guise-sandbox"]
CMD ["bash"]
