include "fm-live-board-projects";
# Pull-request timeline rules for the live board. bin/fm-live-board-prs.sh's
# header owns the fm-live-board-prs.v1 contract these functions read and write;
# bin/fm-live-board-snapshot.sh's header owns the projected pull_requests field.

def lbp_epoch:
  if type != "string" then null
  else (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$") // null) as $m
    | if $m == null then null else
        (try ($m.d + "Z" | fromdateiso8601) catch null) as $t
        | if $t == null or $m.z == "Z" then $t
          else $t + ($m.z | (if .[:1] == "-" then 1 else -1 end)
            * ((.[1:3] | tonumber) * 3600 + (.[4:6] | tonumber) * 60)) end
      end
  end;

# COLLECTION. One run per pipeline or workflow counts: the newest, so a re-run
# that went well replaces the failure it retried.
def lbp_latest: group_by(.name) | map(max_by(.at) | {name,result});

# A merge sets these events off directly or through a chained workflow; a run
# someone started by hand on the merge commit deploys that change too. Timer
# runs only happen to sit on whatever commit is newest, so they are not counted.
def lbp_github_events:
  ["push","workflow_dispatch","workflow_run","deployment","deployment_status","status",
   "check_run","check_suite","repository_dispatch","dynamic"];

# Input: one merge commit of the GitHub query. A check suite with no check run
# is only an installed app that never reported, so it is not a pending deploy.
def lbp_github_runs:
  [(.checkSuites.nodes // [])[]
   | select((.checkRuns.totalCount // 0) > 0)
   | select(.workflowRun == null or (.workflowRun.event as $event | lbp_github_events | index($event) != null))
   | {name:(.workflowRun.workflow.name // .app.name // .app.slug // "unnamed"),at:(.createdAt | lbp_epoch // 0),
      result:(if .status != "COMPLETED" then "running"
        elif .conclusion == "SUCCESS" then "succeeded"
        elif .conclusion == "NEUTRAL" or .conclusion == "SKIPPED" then "skipped"
        elif .conclusion == "CANCELLED" or .conclusion == "STALE" then "superseded"
        else "failed" end)}]
  + [(.status.contexts // [])[]
     | {name:(.context // "unnamed"),at:(.createdAt | lbp_epoch // 0),
        result:(if .state == "SUCCESS" then "succeeded"
          elif .state == "FAILURE" or .state == "ERROR" then "failed" else "running" end)}]
  | lbp_latest;

def lbp_github_prs($cap):
  [.data.repository.pullRequests.nodes[]
   | {number,url,title:(.title // ""),body:((.body // "")[:$cap]),body_truncated:((.body // "") | length > $cap),
      state:(if .state == "MERGED" then "merged" elif .state == "OPEN" then "open" else "closed" end),
      draft:(.isDraft == true),branch:.headRefName,
      opened_at:(.createdAt | lbp_epoch),closed_at:(.closedAt | lbp_epoch),merged_at:(.mergedAt | lbp_epoch),
      runs:(if .state != "MERGED" then {status:"not-merged",items:[]}
        elif .mergeCommit == null then {status:"failed",items:[]}
        else {status:"ok",items:(.mergeCommit | lbp_github_runs)} end)}];

# Input: the runs of one Azure DevOps target branch, newest first, read with a
# limit of $top. A full page means older runs exist that were not read.
def lbp_ado_branch($repo; $top):
  {status:"ok",truncated:(length >= $top),oldest:([.[].queued | lbp_epoch // empty] | min),
   items:[.[] | select(.repo == $repo and .reason != "schedule" and .reason != "pullRequest")
     | {name:(.name // "run \(.id)"),at:.id,sha:.sha,
        result:(if .status != "completed" then "running" elif .result == "succeeded" then "succeeded"
          elif .result == "canceled" then "superseded" else "failed" end)}]};

# Input: the Azure DevOps pull requests; $branches maps a target ref to its
# lbp_ado_branch value, or to {status:"failed"} when its runs were unreadable.
# The list endpoint cuts every description at 400 characters.
def lbp_ado_prs($branches; $base; $cap):
  [.[] | (.merge_commit // "") as $sha
   | ($branches[.target // ""] // {status:"failed"}) as $branch
   | (.closed | lbp_epoch) as $closed
   | {number:.id,url:"\($base)/pullrequest/\(.id)",title:(.title // ""),body:((.description // "")[:$cap]),
      body_truncated:((.description // "") | length >= 400),
      state:(if .status == "completed" then "merged" elif .status == "active" then "open" else "closed" end),
      draft:(.draft == true),branch:((.source // "") | ltrimstr("refs/heads/")),
      opened_at:(.created | lbp_epoch),closed_at:$closed,
      merged_at:(if .status == "completed" then $closed else null end),
      runs:(if .status != "completed" then {status:"not-merged",items:[]}
        elif ($sha | test("^[0-9a-f]{40}$") | not) or $branch.status != "ok" then {status:"failed",items:[]}
        else ([$branch.items[] | select(.sha == $sha)] | lbp_latest) as $items
          | {status:(if ($items | length) == 0 and $branch.truncated and $closed != null
                and $branch.oldest != null and $closed < $branch.oldest then "out-of-window" else "ok" end),
             items:$items} end)}];

# PROJECTION. Everything below turns the collected document into the few
# captain-safe fields that leave the snapshot; a pull request body never does.

def lbp_url:
  if type == "string"
    and (test("^https://github\\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}/pull/[1-9][0-9]{0,8}$")
      or test("^https://dev\\.azure\\.com/[A-Za-z0-9][A-Za-z0-9-]{0,62}/[A-Za-z0-9._-]{1,64}/_git/[A-Za-z0-9._-]{1,64}/pullrequest/[1-9][0-9]{0,8}$"))
  then . else null end;

def lbp_valid:
  type == "object" and .schema == "fm-live-board-prs.v1"
  and (.collected_at_epoch | type == "number") and (.repos | type == "array")
  and all(.repos[]; type == "object" and (.project | type == "string" and length > 0)
    and (.status | IN("ok","failed","none")) and ((.prs // []) | type == "array"));

def lbp_valid_pr:
  type == "object" and (.number | type == "number") and (.url | lbp_url != null)
  and (.state | IN("open","merged","closed")) and ((.title // "") | type == "string")
  and ((.body // "") | type == "string") and ((.runs // {}) | type == "object")
  and ((.runs.items // []) | type == "array" and all(.[]; type == "object" and (.name | type == "string")));

# The ship branch is the registered prefix plus the task id, which is what
# places a pull request in one of the captain's named projects.
def lbp_task($prefix):
  if type != "string" then null
  elif ($prefix | length) > 0 and (startswith($prefix) | not) then null
  else ltrimstr($prefix) | if test("^[A-Za-z0-9._-]{1,128}$") then . else null end end;

def lbp_cut($max):
  if length <= $max then .
  else .[:$max] | sub("\\s+\\S*$"; "") | sub("[\\s,;:(-]+$"; "") | . + "..." end;

def lbp_plain_md:
  gsub("\r"; "")
  | gsub("<!--[\\s\\S]*?(-->|$)"; " ")
  | gsub("```[\\s\\S]*?(```|$)"; "\n\n")
  | gsub("!\\[[^\\]]*\\]\\([^)]*\\)"; "")
  | gsub("\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; .t)
  | gsub("</?[A-Za-z][^>]*>"; " ")
  | gsub("\\s*[\u2013\u2014]\\s*"; " - ")
  | gsub("`"; "");

# Lines that say nothing about the change: checklists, tool signatures,
# tables, rules, ticket pointers and one-word metadata.
def lbp_noise:
  test("^[-*+]\\s*\\[[ xX]\\]")
  or test("generated with|co-authored-by:|signed-off-by:"; "i") or contains("🤖")
  or test("^\\|") or test("^([-*_=]\\s*){3,}$")
  or test("^(fix(es|ed)?|close[sd]?|resolve[sd]?|refs?|related( to)?|ticket|task|issue|work item|see)s?:?\\s*[#A-Za-z0-9 ,/!&-]*[#0-9][#A-Za-z0-9 ,/!&-]*$"; "i")
  or test("^[A-Za-z][A-Za-z -]{0,24}:\\s*\\S+$");

def lbp_heading_words: ["intent","summary","why","what","description","overview","problem","context"];

# Prose paragraphs under each heading; a line that is only bold text is a
# heading too, and list items are detail, never the summary.
def lbp_sections:
  reduce (split("\n")[] | sub("^\\s*(>\\s*)*"; "") | sub("\\s+$"; "")) as $raw ({out:[{heading:null,paras:[]}],open:false};
    ($raw | sub("^\\*\\*(?<h>[^*]+)\\*\\*:?$"; "## " + .h) | gsub("\\*\\*|__|~~"; "")) as $line
    | ($line | ascii_downcase | sub(":$"; "")) as $bare
    | if ($line | test("^#{1,6}(\\s|$)")) then
        .out += [{heading:($line | gsub("^#+\\s*|[\\s#:]*$"; "") | ascii_downcase),paras:[]}] | .open = false
      elif any(lbp_heading_words[]; . == $bare) then .out += [{heading:$bare,paras:[]}] | .open = false
      elif $line == "" or ($line | lbp_noise) or ($line | test("^([-*+]|[0-9]+[.)])\\s+")) then .open = false
      elif .open then .out[-1].paras[-1] += " " + $line
      else .out[-1].paras += [$line] | .open = true end)
  | .out;

def lbp_source:
  (lbp_plain_md | lbp_sections) as $sections
  | first(lbp_heading_words[] as $want
      | $sections[] | select(.heading != null and (.heading | startswith($want)) and (.paras | length) > 0) | .paras)
    // first($sections[] | select((.paras | length) > 0) | .paras) // [];

# A sentence that only introduces a list or quote says nothing once that
# detail is dropped, so it is not a sentence here.
def lbp_sentences:
  map(if test("[.!?:][\"')]?$") then . else . + "." end) | join(" ")
  | gsub("\\be\\.g\\.,?"; "for example") | gsub("\\bi\\.e\\.,?"; "that is") | gsub("\\betc\\.(?=\\s+[a-z])"; "etc")
  | [splits("(?<=[.!?:])\\s+(?=[\"'(]?[A-Z0-9])") | select(test("[A-Za-z]") and (test(":$") | not))];

# Pointers a manager cannot follow: run and build numbers, ticket references
# and command flags, then the holes their removal leaves behind.
def lbp_plain($ids):
  gsub("\\b(run|build|job)\\s+#?[0-9]{3,}\\b"; ""; "i")
  | gsub("(?<![A-Za-z0-9])(AB)?#[0-9]+"; "")
  | gsub("(?<![A-Za-z0-9-])--[A-Za-z][A-Za-z0-9-]*"; "")
  | lb_clean($ids)
  | if . == null then null else
      gsub(",(\\s*,)+"; ",") | gsub("\\(\\s*[,;]\\s*"; "(") | gsub("\\s*,\\s*\\)"; ")")
      | gsub("\\s*\\(\\s*\\)"; "")
      | if startswith("\"") and (([scan("\"")] | length) % 2 == 1) then .[1:] else . end
      | if length == 0 then null else . end
    end;

# Mostly ordinary words: of the tokens that carry a letter or digit, at most
# three in twenty may be a name with digits, slashes, underscores or dots.
def lbp_readable:
  ([splits("\\s+") | select(test("[A-Za-z0-9]"))]) as $tokens
  | ([$tokens[] | select(test("^[(\"']?[A-Za-z][A-Za-z'-]*[)\"',.;:!?]*$"))] | length) * 20 >= ($tokens | length) * 17;

# Words outside brackets. Cleaning that removes one of them leaves a sentence
# with a hole in it, which reads worse than no sentence.
def lbp_outer_words: gsub("\\([^()]*\\)"; " ") | [splits("\\s+") | select(test("[A-Za-z0-9]"))] | length;

# The title without its commit-style prefix. Cleaning that would leave a hole
# keeps the title as written instead: a technical title still names the change.
def lbp_title($ids):
  if type != "string" then null else
    gsub("[\\x00-\\x1f\\x7f]"; " ")
    | sub("^\\s*(\\[[^\\]]*\\]\\s*)+"; "")
    | sub("^\\s*(revert:?\\s+)?((feat|fix|docs?|chore|ci|refactor|tests?|perf|build|style|hotfix|revert)|[a-z]+(?=\\())(\\([^)]*\\))?!?:\\s*"; ""; "i")
    | sub("\\s*\\(#[0-9]+\\)\\s*$"; "")
    | gsub("https?://\\S+"; "") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
    | . as $written
    | (lbp_plain($ids)) as $clean
    | (if $clean != null and ($clean | lbp_outer_words) == ($written | lbp_outer_words) then $clean else $written end)
    | if length == 0 then null else (.[:1] | ascii_upcase) + .[1:] | lbp_cut(140) end
  end;

# The manager note: up to three sentences and 320 characters from the
# description's intent, summary or first prose paragraph. Readability is judged
# on each sentence as written, before cleaning hides what made it technical; the
# note stops at the first sentence that fails or loses a word to cleaning, and
# is null when under 40 characters are left, so the cleaned title stands alone.
def lbp_summary($ids; $truncated):
  if type != "string" then null else
    lbp_source as $paras
    # A description the forge cut off ends mid-sentence: that tail is dropped
    # when a whole sentence precedes it, and otherwise ends in an ellipsis.
    | ($truncated and ($paras | length) > 0 and ($paras[-1] | test("[.!?:][\"')]?$") | not)) as $cut
    | ($paras | lbp_sentences) as $all
    | (if $cut and ($all | length) > 1 then $all[:-1] else $all end) as $kept
    | reduce $kept[:3][] as $sentence ({text:"",count:0,stop:false};
        if .stop then . else
          (if $sentence | lbp_readable then $sentence | lbp_plain($ids) else null end) as $clean
          | if $clean == null or ($clean | lbp_outer_words) != ($sentence | lbp_outer_words) then .stop = true
            elif (.text | length) + ($clean | length) > 320 then
              (if .count == 0 then .text = ($clean | lbp_cut(300)) | .count = 1 else . end) | .stop = true
            else .text += (if .count > 0 then " " else "" end) + $clean | .count += 1 end
        end)
    | .text
    | if length < 40 then null
      elif $cut and ($all | length) == 1 then sub("[.\\s]*$"; "...")
      elif test("[.!?][\"')]?$") then . else . + "." end
  end;

# DEPLOY OUTCOME. The one rule that reads the result of the runs a pull
# request's merge started:
#   not-deployed  open or closed unmerged, or merged under $grace seconds ago
#                 in a repository whose merges do start runs
#   failed        a counted run failed; running: none failed, one is unfinished
#   succeeded     every counted run succeeded
#   none          merged with no counted run: `superseded` when a run of its
#                 own was cancelled or replaced, else `project` when no merge
#                 in the window started one and `change` when other merges did
#   unknown       the runs could not be read, or are older than the window
def lbp_deploy($has_runs; $now; $grace):
  ([(.runs.items // [])[] | select(.result | IN("failed","running","succeeded"))]
   | sort_by([({"failed":0,"running":1}[.result] // 2),.name])) as $counted
  | (if .state == "open" then {outcome:"not-deployed",why:"open"}
     elif .state != "merged" then {outcome:"not-deployed",why:"closed"}
     elif .runs.status == "failed" then {outcome:"unknown",why:"unreadable"}
     elif any($counted[]; .result == "failed") then {outcome:"failed",why:"run-failed"}
     elif any($counted[]; .result == "running") then {outcome:"running",why:"run-unfinished"}
     elif ($counted | length) > 0 then {outcome:"succeeded",why:"runs-succeeded"}
     elif any((.runs.items // [])[]; .result == "superseded") then {outcome:"none",why:"superseded"}
     elif .runs.status == "out-of-window" then {outcome:"unknown",why:"too-old"}
     elif $has_runs | not then {outcome:"none",why:"project"}
     elif .merged_at != null and $now - .merged_at < $grace then {outcome:"not-deployed",why:"waiting"}
     else {outcome:"none",why:"change"} end)
  + (if .state == "merged" then
       {runs:[$counted[:8][] | {name:(.name | gsub("[\\x00-\\x1f\\x7f]"; " ") | .[:60]),result}],
        more_runs:([($counted | length) - 8, 0] | max)}
     else {runs:[],more_runs:0} end);

# $doc is the collected document, null when none was collected, or any other
# value when the collected file could not be read.
def lbp_project($doc; $known_ids; $now):
  if $doc == null then {status:"not-collected",collected_at_epoch:null,repos:[]}
  elif $doc | lbp_valid | not then {status:"unreadable",collected_at_epoch:null,repos:[]}
  else
    [$doc.repos[] | (.branch_prefix // "fm/") as $prefix
     | . + {prefix:$prefix,prs:[(.prs // [])[] | select(lbp_valid_pr)]}] as $repos
    | ($known_ids + [$repos[] | .prefix as $prefix | .prs[].branch | lbp_task($prefix) // empty]
       | map({key:.,value:true}) | from_entries) as $ids
    | {status:"collected",collected_at_epoch:$doc.collected_at_epoch,
       repos:[$repos[] | .prefix as $prefix
         | any(.prs[]; any((.runs.items // [])[]; .result | IN("failed","running","succeeded"))) as $has_runs
         | {project,forge:(.forge // "none"),status,reason:(.reason // null),
            prs:[.prs[] | (.body_truncated == true) as $truncated
              | {number,url,state,draft:(.draft == true),
              task:(.branch | lbp_task($prefix)),
              title:((.title | lbp_title($ids)) // "Untitled change"),
              summary:(.body | lbp_summary($ids; $truncated)),
              at:(.merged_at // .closed_at // .opened_at),
              deploy:lbp_deploy($has_runs; $now; 900)}]}]}
  end;
