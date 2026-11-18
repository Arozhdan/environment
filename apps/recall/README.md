# recall

Recall is the owner's memory for AI agents ([Arozhdan/recall](https://github.com/Arozhdan/recall)).
This app runs its background program: one pod that reads Claude Code's (and later Pi's) session
files, keeps what is worth remembering in `~/.recall/archive.db`, backs it up every night, and
answers `recall` on a socket in `~/.recall`. It has no web page, no service and no ingress.

The pod runs as the owner's user (uid 1000) and sees the owner's home folder, read-only, at the
same path as on the host (`/home/develop`), so the look tools can open the owner's repositories.

## What the pod sees

| Path in the pod | What it is | Pod can |
| --- | --- | --- |
| `/home/develop` | the whole home folder | read only |
| `/home/develop/.recall` | data folder: archive, Pi Durable's file, backups, status, socket, `settings.yaml` | read and write |
| `/home/develop/.recall/claude-hook` | the hook Claude Code runs on the host | read only |
| `/home/develop/.claude` | covered: looks empty, apart from `projects` | nothing |
| `/home/develop/.claude/projects` | Claude Code's session files | read only |
| `.ssh`, `.config`, `.t3`, `.kube`, `.docker`, `.cloudflared`, `.pki`, `.local`, `.cache`, `.mcp-auth`, `.infisical`, `.terraform.d`, `.codex`, `.gemini`, `.copilot`, `.cursor`, `.opencode`, `.kilocode`, `.zai`, `.codeium`, `.supermaven`, `.warp`, `.claude-mem`, `.convex`, `.expo`, `.app-store`, `.pm2`, `.ansible`, `.alchemy`, `.postplan`, `.hyperframes`, `.tma`, `.bun`, `.vnc`, `.cursor-server`, `.vscode-server`, `.antigravity-server`, `.zed_server`, `snap`, `actions-runner-opside`, `actions-runner-opside2` | sign-ins, keys, tokens, tool state | nothing: each is covered by an empty read-only folder |
| `/tmp` | scratch | read and write (emptied at restart) |

The list of covered folders is in two places that must agree: the `hidden` mounts in
`deployment.yaml` and `hidden` in `check.yaml`. `scan-home.sh` stops with exit code 2 when they
do not.

**When a covered folder is missing** the pod does not start (the folder for the cover cannot be
made inside the read-only home). That fails closed: delete a covered folder on the host and
the pod stays down until you remove it from both lists.

**When a covered folder is deleted or replaced while the pod runs**, the kernel drops the cover
and the pod sees the new folder. The liveness check (`check.yaml`) looks every 20 seconds and
restarts the pod within about a minute; the restart covers the folder again.

**Files right in the home folder are not covered** (`.claude.json`, `.npmrc`, shell history):
a cover over a file comes off as soon as the program that owns it writes it anew by renaming,
which Claude Code does all the time. Folders that appear later (a new tool's sign-in folder)
are visible too until they are added to the list. The scan below shows both.

## Before merging (the owner, in order)

1. Make the data folder as your own user: `mkdir -p ~/.recall/backups && chmod 700 ~/.recall`.
2. Put the settings in it: `cp ~/applications/recall/settings.example.yaml ~/.recall/settings.yaml`,
   then set `modelApi.address` and, under `connectors`, `claude: { folder: /home/develop/.claude/projects }`
   and `pi: { folder: /home/develop/.pi/agent/sessions }`, and `sleep.homeFolders: [/home/develop]`.
   Write paths in full: the pod and the recall step on the host both read this file.
   The model API must be reachable on a public address over HTTPS (port 443): the network
   rule allows nothing else (not the cluster's own services, not a private address).
3. Install the Claude Code hook on the host, which makes `~/.recall/claude-hook`
   (the pod does not start without it): in `~/applications/recall`,
   `vp run @recall/recall-claude#build && recall install claude`.
4. Add the image pull secret: `sops secrets/recall/recall-env.enc.yaml` and add, under
   `secretTemplates`, a second entry with a token that may read `ghcr.io/arozhdan/recall`
   (the one in `folio-ghcr` works if its token covers this package):

   ```yaml
   - name: recall-ghcr
     type: kubernetes.io/dockerconfigjson
     stringData:
       .dockerconfigjson: '{"auths":{"ghcr.io":{"auth":"<base64 of user:token>"}}}'
   ```

5. Run the key scan and read its list: `bash ~/environment/apps/recall/scan-home.sh --visible`.
   It looks at file names only. For every `VISIBLE` line decide: fine, move it, delete it, or add
   its folder to both lists. It exits 1 while anything is visible.

## After the merge

```sh
kubectl -n recall get pods                     # one pod, Running, 1/1
recall status                                  # on the host: "Background program: running"

# nothing in the home folder, a project or the sessions can be written (each: Read-only file system)
kubectl -n recall exec deploy/recall -- touch /home/develop/recall-write-test
kubectl -n recall exec deploy/recall -- touch /home/develop/applications/recall/recall-write-test
kubectl -n recall exec deploy/recall -- touch /home/develop/.claude/projects/recall-write-test

# the covered folders show nothing (prints a number, then the folder: every number must be 0)
kubectl -n recall exec deploy/recall -- sh -c 'while read -r d; do echo "$(ls -A "$d" | wc -l) $d"; done < /etc/recall/hidden'
kubectl -n recall exec deploy/recall -- ls -A /home/develop/.claude          # only: projects
kubectl -n recall exec deploy/recall -- ls /home/develop/.claude/.credentials.json   # No such file
kubectl -n recall exec deploy/recall -- sh /etc/recall/check.sh && echo ok    # the liveness check
```

## Stop, start, remove

- Stop: `kubectl -n recall scale deployment recall --replicas=0` (Argo CD leaves it stopped).
  Start again with `--replicas=1`.
- Remove: delete `apps/recall` and `secrets/recall` in a pull request; Argo CD removes the pod,
  the volumes and the namespace. The host folders stay as they are (the volumes are `Retain`).
  Then, on the host, `recall remove claude`, and delete `~/.recall` if you want the data gone.

## When Pi is installed

Pi keeps its sign-in in `~/.pi/agent/auth.json` and its sessions in `~/.pi/agent/sessions`.
Scale the pod to 0 before installing Pi (a running pod sees a new `~/.pi` at once), then:
cover `/home/develop/.pi` the way `.claude` is covered (an emptyDir, the init container making
`agent/sessions` in it), mount back a new volume for `/home/develop/.pi/agent/sessions`
read-only, mount `~/.recall/pi-extension` read-only after `recall install pi`, and add the
matching lines to `check.sh`. Then run the scan again.
