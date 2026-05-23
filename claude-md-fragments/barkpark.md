# Barkpark paper streaming

Barkpark is a local HTTP service that ingests papers (specs, plans, research notes)
for indexing and retrieval. When `--with-barkpark` is enabled, paperflow can stream a
finished doc to your local Barkpark instance instead of only writing it to disk.

The ingest contract lives in `~/.paperflow/barkpark.env` (written by `install.sh`):

    BARKPARK_INGEST_URL=http://127.0.0.1:4000/api/papers/ingest
    BARKPARK_INGEST_TOKEN=barkpark-dev-token

`BARKPARK_INGEST_URL` is the POST endpoint; `BARKPARK_INGEST_TOKEN` is the bearer token
sent in the `Authorization: Bearer <token>` header. Both default to the local dev values
above — edit `~/.paperflow/barkpark.env` to point at a different host or to use a real
token. Because Barkpark is a local HTTP service, the install does no binary check; if the
service is down the stream simply fails and the doc still lands on disk as usual.
