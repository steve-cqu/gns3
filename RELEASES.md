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

### Post-release fixes

Listed because a fix means some students' appliances no longer match the release they were
given, and that difference is invisible otherwise.

| Release | Date | Fix | How it reached students |
| --- | --- | --- | --- |
| `v027` | 31 Jul 2026 | `server/vm-fix-persistence.sh` — sets `extra_volumes` on the Docker templates so node configuration survives closing a project | Students ran `git pull` in `~/git/gns3` on the VM and ran the script, per the *Saving Your Work* guide |

That `git pull` is the exception, not the mechanism. A released appliance is a finished
artefact; students are not normally expected to touch the repo on it at all.

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
5. Add the row above, with the OVA filenames, sizes and sha256 sums.
6. Publish the handout projects for the term alongside the OVA: the templates students
   complete, the solutions for staff, and `SDN-Basics-Template` (729 MB — too large for a
   Moodle upload, so it is hosted with the OVA and linked from there).
7. Tell students which version to use this term, and to delete the previous one.
