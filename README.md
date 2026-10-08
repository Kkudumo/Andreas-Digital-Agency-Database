# ADA Core

The central, secure, portable data and rules layer of Andreas Digital Agency. One source of truth for
organization, staff, recruitment, clients, projects and public website data. **ADA IRM** (the internal
interface) and every public website are clients of this database; none of them keeps its own copy of ADA's data.

| | |
|---|---|
| Start here | [docs/README.md](docs/README.md) — architecture, decisions, status |
| Run the tests | `./scripts/test-db.sh` (needs local PostgreSQL 16 + Node; see [docs/operations/DEVELOPMENT.md](docs/operations/DEVELOPMENT.md)) |
| Rehearse a server move | `./scripts/rehearse-migration.sh` |

## Layout

```
supabase/migrations/   the schema, in order, and the only way the schema changes
supabase/seed_data/    permission_matrix.csv — the reviewed permission matrix (tests require DB == CSV)
supabase/tests/        authorization, integrity, public-exposure and scenario tests (+ Supabase stand-in for local runs)
scripts/               test runner, backup/restore, migration rehearsal, doc generators
docs/                  architecture, security, API, workflows, operations
web/                   ADA IRM scaffold — PAUSED until the backend modules are finished
```
