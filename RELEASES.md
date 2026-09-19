# GNS3 VM releases

Which appliance each cohort was given, and what went into it.

A **build** is any run of `server/ansible/build.sh`. A **release** is a build that was cut to
an `.ova` and handed to students. Only releases appear here. Version numbers count builds,
not terms, so the sequence has gaps — v023–v026 and v028+ were built and never released.

Students are told which release to use at the start of term, and to delete the previous one.
Old appliances are never rebuilt or patched.

**From August 2026 a release is two OVAs, not four.** Releases up to and including `v027`
came in student and staff variants, the staff one carrying the 17 solution projects; the
appliance now ships five demonstration projects and goes to both audiences unchanged, with
templates and solutions handed out through Moodle. Rows below `v027` should be read with that
in mind — their `-student` / `-staff` filenames are not a naming convention that still exists.

## Released

| Version | Term | Released | `gns3` | `gns3-dev` | Notes |
| --- | --- | --- | --- | --- | --- |
| `v027` | T2 2026 | 23 Jun 2026 | [`509278c`](https://github.com/steve-cqu/gns3/commit/509278c) (19 Jun 2026) | [`7e444b5`](https://github.com/steve-cqu/gns3-dev/commit/7e444b5) (23 Jun 2026) | One post-release fix issued — see below |
| `v022` | T1 2026 | ~mid-Mar 2026 | [`5937d74`](https://github.com/steve-cqu/gns3/commit/5937d74) (4 Nov 2025) | [`2e77343`](https://github.com/steve-cqu/gns3-dev/commit/2e77343) (3 Nov 2025) | First release |

Both rows were reconstructed on 5 Aug 2026, after the fact — neither build stamped itself.
They are the best available evidence, not a recorded fact:

- **v022** is firm. `gns3` has no commits at all between 4 Nov 2025 and 13 Apr 2026, so the
  T1 appliance can only have come from the end of that November work.
- **v027** is firm on the `gns3` side (19 June is the last commit before the 23 June upload,
  and matches the remembered 13 Apr – 19 Jun window) and confirmed on the `gns3-dev` side.

Every release from v030 on is stamped at build time and needs no reconstruction.

### Keys in this repository's history

Four private SSH keys are retrievable from this repository's git history:
`server/docker/{alpinenode,ubuntunode}/gns3_student_{ed25519,rsa}_key.prv`, added in September 2025
and June 2026 and removed on 5 August 2026.

**They authorise nothing.** They were the shared lab key pair baked into the `alpinenode` and
`ubuntunode` images up to `v027`, whose containers run with the published lab password `gns3`
anyway and exist only inside a student's own virtual network. They grant no access to any CQU
system, to any appliance built since, or to anything on the internet. The images stopped shipping
them on 5 August 2026, when the shared pair was removed and `start-sshd` reworked.

They are documented here rather than purged. Rewriting history would change every commit hash —
including the ones the rows above cite as the definition of what each cohort received — and the
provenance record is worth more than removing keys that authorise nothing. Decided 19 September
2026 (public-repo review, D10).

### Post-release fixes

Listed because a fix means some students' appliances no longer match the release they were
given, and that difference is invisible otherwise.

| Release | Date | Fix | How it reached students |
| --- | --- | --- | --- |
| `v027` | 31 Jul 2026 | `server/vm-fix-persistence.sh` — sets `extra_volumes` on the Docker templates so node configuration survives closing a project | Students ran `git pull` in `~/git/gns3` on the VM and ran the script, per the *Saving Your Work* guide |

That `git pull` is the exception, not the mechanism. A released appliance is a finished
artefact; students are not normally expected to touch the repo on it at all.

**That fix is now in the build** (13 Aug 2026). The directories live in `extra_volumes` in the
`templates/docker-*.conf` files, so the `templates` phase installs them and every release from
the next one on ships with persistence already set — no script, no `git pull`. `v027` appliances
still need the script, which is why it is still in the repository and still in the guide.
See [Node persistence](server/README.md#what-survives-a-project-being-closed).

## What a release records

The build writes `/home/gns3/gns3-build-provenance.json` on the appliance, and a released
build also files a copy per profile under `server/releases/<version>/` — two files, `amd64`
and `arm64`, since those are built from different images. It records the release label, both
repository commits, GNS3 and kernel versions, every Docker image ID, every Qemu disk md5,
every template and project, and the size + sha256 of each source `.gns3project`.

This is **provenance, not reproducibility**. The Docker builds install from upstream
package repositories, so rebuilding an old tag today will not reproduce that release's
images. The record tells you what a student is running when they report a fault; it is not
a recipe for recreating it.

A released appliance also carries `/etc/gns3-cqu-release`, so it can name itself:

```
$ cat /etc/gns3-cqu-release
GNS3_CQU_RELEASE=v030
GNS3_CQU_PROFILE=amd64
...
```

That is the check to give a student or a tutor who needs to confirm they are on this term's
appliance — a renamed `.ova` proves nothing, and the shell shows the same line on login.

## Cutting a release

The steps below are the release itself. For the surrounding cycle — when in the term each
step is safe, what has to land before a build, and how to handle a fix to an appliance
already in students' hands — see `gns3-dev/notes/term-rollover-runbook.md` in the private
repo.

1. Commit everything in both repositories. The build warns if either work tree is dirty,
   because a dirty tree cannot be pointed back at a tag.
2. Build with the release label, once per architecture:
   ```sh
   ./build.sh <vm> amd64 -e release=v030 -e verify=all
   ```
   This stamps the appliance and files the manifest under `server/releases/v030/`.
   Use `verify=all`: it is the only check that the appliance still runs the activities
   students import for themselves, since the appliance ships only demonstration projects.
3. Cut the OVA — section 3 of [`server/README.md`](server/README.md). Still manual.
   Two OVAs per release, `amd64` and `arm64`. There is no separate staff appliance: staff
   and students get the same file, and the solutions go out through Moodle.
4. Tag **both** repositories with the same label, since `server/build/manifest.yml` takes
   the projects from `gns3-dev`, and a `gns3` tag alone does not describe an appliance:
   ```sh
   git -C gns3     tag -a v030 -m "GNS3 VM v030 — T3 2026"
   git -C gns3-dev tag -a v030 -m "GNS3 VM v030 — T3 2026"
   git -C gns3 push origin v030 && git -C gns3-dev push origin v030
   ```
5. Add the row above, with the OVA filenames, sizes and sha256 sums. **Neither existing row
   has them** — both were reconstructed after the fact — so v030 is the first release that can
   honour this, and the size is what `vm/virtualbox.md` tells students to check with you when
   they suspect a corrupt download.
5a. **Archive the release to the shared drive.** The appliance is frozen for years, not months,
   and a from-source rebuild in 2028 depends on upstreams that will have moved or gone. Freeze
   the built images, tar the Qemu disks, bundle both repos, and copy
   [`server/RESTORE.md`](server/RESTORE.md) in with its header filled out — it tells whoever
   opens that folder later which restore path to use. Commands are in `RESTORE.md` under
   *Making the archive*. Do this **after** `verify=all` passes, never before: an archive of an
   unverified set is worse than none, because it looks authoritative.
6. Publish the handout projects for the term: the templates students complete and the
   solutions for staff, through Moodle. Nothing is too large to upload any more —
   `SDN-Basics-Template` (729 MB) was the only project that had to be hosted beside the OVA,
   and it was retired in August 2026 when the SDN controller became `cqugns3/faucetnode`.
7. Tell students which version to use this term, and to delete the previous one.
