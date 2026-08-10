# data/

Files students fetch **by URL**, not by anything in this repository.

Nothing here is referenced by the build, the manifest or any document in this repo, so a grep
across `gns3/` makes these look orphaned. They are not — they are downloaded over
`raw.githubusercontent.com` by activity instructions that live in the private `gns3-dev` repo.
Deleting or moving one breaks a copy-paste command in a student handout, and nothing here
would fail first to warn you.

| File | Fetched by |
|---|---|
| `sdn/faucet-4hosts-2vlan-1.yaml` | `gns3-dev/activities/sdn-basics/` — instructions and solution |
| `sdn/faucet-2hosts-1vlan-1.yaml` | the smaller Faucet config for the same activity |

The URL form is `https://raw.githubusercontent.com/steve-cqu/gns3/refs/heads/main/data/<path>`,
which tracks `main` — so a change here reaches students immediately, including mid-term. Treat
edits with the same care as a published handout.
