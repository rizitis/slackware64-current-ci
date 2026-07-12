# Docker image

A minimal, bootstrappable Slackware64-current container built on [Slackware64-Current-sofiles](https://github.com/rizitis/Slackware64-Current-sofiles)
repository's dependency database. ~54MB pull, 31 packages + [slacker](https://github.com/rizitis/slacker).

```
docker pull ghcr.io/rizitis/slackware64-current-ci:slacker-very_mini-testing
docker run --rm -it ghcr.io/rizitis/slackware64-current-ci:slacker-very_mini-testing
```

The image ships **without** gnupg and without a system CA store - slacker's TLS
uses rustls with bundled roots, and packages are verified in two stages:

1. `slacker update` - fetches repo metadata **and this repo's depgraph.db**
   (md5-verified over HTTPS).
2. `slacker install gnupg2` - resolve-stock reads the db's precomputed
   `closure` table and pulls exactly the crypto chain (15 packages, not 300).
3. `slacker update gpg` - pins the Slackware signing key (TOFU); flip
   `VERIFY=all` in `/etc/slacker/slacker.conf` for full GPG verification from
   then on.

From there, `slacker install <anything>` works: the closure table knows what
every stock package needs to *run* on a bare system (library-loader chains
only - tool-only deps never cascade). Build script: [`docker/slacker-docker.sh`](docker/slacker-docker.sh).

Wiki-HowTo:  [slacker-docker](https://forge.slackware.nl/rizitis/slacker/wiki/Docker)
