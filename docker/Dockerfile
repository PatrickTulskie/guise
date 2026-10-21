# A disposable machine to run guise against: the same Linux tooling CI uses,
# and a $HOME that setup, rename and uninstall can wreck for free.
FROM golang:1.26-bookworm

# git and ssh-keygen are what guise itself shells out to; perl carries
# shasum, which the suite hashes artifacts with; jq is the op stub's; zsh
# makes the shell hook exercisable instead of skipped. op, op-cache, curl and
# gh stay stubbed.
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
COPY docker/rebuild.sh /usr/local/bin/guise-rebuild
RUN chmod 755 /usr/local/bin/guise-sandbox /usr/local/bin/guise-rebuild \
 && useradd --create-home agent

USER agent
WORKDIR /work

# The human this machine belongs to, so the commit hook's co-author fallback
# has something to fall back to.
RUN git config --global user.name "Human" \
 && git config --global user.email "human@example.com" \
 && git config --global init.defaultBranch main

# Modules and a first build cached in the image, so the build the entrypoint
# does against the working tree takes a second and needs no network.
COPY --chown=agent go.mod go.sum /tmp/warm/
COPY --chown=agent cmd /tmp/warm/cmd
RUN cd /tmp/warm && go mod download && go build -o /dev/null ./cmd/guise && rm -rf /tmp/warm

ENTRYPOINT ["/usr/local/bin/guise-sandbox"]
CMD ["bash"]
