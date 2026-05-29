# Barkpark paper streaming

Barkpark is a local HTTP service that ingests papers (specs, plans, research notes)
for indexing, live render, and retrieval. When `--with-barkpark` is enabled, paperflow
streams a finished doc to your local Barkpark instance in addition to writing it to disk.

## Pairing

`install.sh --with-barkpark` **pairs** paperflow with a local Barkpark by writing the
ingest contract to `~/.paperflow/barkpark.env` (0600 — it holds a secret):

    BARKPARK_INGEST_URL=http://localhost:4000/v1/paperflow/papers
    BARKPARK_INGEST_TOKEN=bk_<minted-once-reused-forever>

- `BARKPARK_INGEST_URL` is the POST endpoint the save seam (`hooks/event-on-save.sh`)
  streams to. It points at the local Barkpark on `:4000`.
- `BARKPARK_INGEST_TOKEN` is the bearer token sent as `Authorization: Bearer <token>`.
  It is **minted once** on the first `--with-barkpark` and **reused** verbatim on every
  later run — re-running the installer never regenerates it. Edit the file to point at a
  different host or to set your own token; the next install run reuses whatever is there.

The pairing is written whether or not Barkpark is installed — there is no binary check
and no hard-fail. If the `barkpark` launcher is found (`bin/barkpark` from Wave 5, or
`barkpark` on PATH) the installer notes how to start the service.

## Starting Barkpark

`barkpark up` brings up a personal-local Barkpark: it ensures secrets, starts a managed
Postgres, migrates, and boots the Phoenix server **serving `http://localhost:4000`**.
Re-runnable. After editing `~/.barkpark/.env` (e.g. a token), run `barkpark reload` —
Barkpark reads its env at boot only, so a running server keeps the old value until
restarted.

## Localhost-optional ingest auth

Barkpark supports **localhost-optional ingest auth**: when it is started with
`INGEST_ALLOW_LOCALHOST=true`, ingest requests coming from loopback (127.0.0.1 / ::1)
are accepted **without a token** — the personal-local convenience, since nothing leaves
the machine. Remote (non-loopback) callers always still need the token, and with the
flag off (the default) the token is required for everyone.

So a personal-local pairing where paperflow and `barkpark up` run on the same machine
needs no token at all once Barkpark has `INGEST_ALLOW_LOCALHOST=true`. The token in
`~/.paperflow/barkpark.env` is written regardless, so the seam still authenticates
against a remote Barkpark, or a default-config local one that requires the token.

Because Barkpark is a local HTTP service, the install does no binary check; if the
service is down the stream simply fails and the doc still lands on disk as usual.
