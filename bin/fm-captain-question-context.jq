# Mechanical implementation of the context contract owned by fm-captain-hold.sh.
# Shared by its pure codec and the thin live-board projection, never a state reader.
# Reject duplicate JSON member names before normalization can erase ambiguity.
def fm_question_json_decode:
  . as $text | fromjson as $decoded
  | reduce ($text | scan("\"(?:[^\"\\\\]|\\\\.)*\"|\\{|\\}|\\[|\\]|:")) as $token
      ({stack:[],key:null,duplicate:false};
       if $token == "{" or $token == "[" then .stack += [{seen:{}}]
       elif $token == "}" or $token == "]" then .stack = .stack[:-1]
       elif $token == ":" then
         if .stack[-1].seen[.key] then .duplicate = true else .stack[-1].seen[.key] = true end
       else .key = ($token | fromjson) end)
  | if .duplicate then error("duplicate question context member") else $decoded end;
def fm_question_slug($max):
  type == "string" and length > 0 and length <= $max
  and test("^[A-Za-z0-9._-]+$");
def fm_question_timestamp:
  type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
  and (try ((fromdateiso8601 | todateiso8601) == .) catch false);
def fm_question_lifecycle_valid:
  type == "string" and length <= 64 and test("^[^#]+#(0|[1-9][0-9]*)$")
  and (split("#")[0] | fm_question_timestamp);
def fm_question_text($max; $newlines):
  type == "string" and length > 0 and length <= $max and test("[^[:space:]]")
  and (test(if $newlines then "[\\x00-\\x09\\x0b-\\x1f\\x7f]" else "[\\x00-\\x1f\\x7f]" end) | not);
def fm_question_valid($stored):
  type == "object"
  and ((keys - (["schema","close","about","purpose","question","options","recommendation","subject"]
    + if $stored then ["lifecycle"] else [] end)) | length == 0)
  and .schema == "fm-captain-question.v1" and (.close | IN("done","release"))
  and (if $stored then (.lifecycle | fm_question_lifecycle_valid) else true end)
  and (.about == null or (.about | fm_question_text(600; false)))
  and (.purpose == null or (.purpose | fm_question_text(600; false)))
  and (.question == null or (.question | fm_question_text(600; true)))
  and ((.options // []) | type == "array" and length <= 12
    and all(.[]; type == "object" and (keys == ["label","value"] or keys == ["detail","label","value"])
      and (.value | fm_question_slug(64)) and .value != "reconcile"
      and (.label | fm_question_text(120; false))
      and (.detail == null or (.detail | fm_question_text(300; false))))
    and (map(.value) | length == (unique | length)))
  and (.recommendation as $recommendation
    | $recommendation == null or any((.options // [])[]; .value == $recommendation))
  and (.subject == null or (.subject | type == "object" and keys == ["artifact","version"]
    and (.artifact | fm_question_slug(128))
    and (.version | type == "string" and length <= 64 and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))));
# Authoring gate only: a stored call that predates it stays valid and the board
# marks it instead.
# The first unmet plain-language rule, or null when a manager can read the call.
def fm_question_explanation_problem:
  if .about == null or .purpose == null then "missing"
  elif any(.about, .purpose;
    test("https?://|`|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"))
    then "markup"
  elif any((.options // [])[]; .detail == null) then "option"
  else null end;
# An active call may gain the explanation it lacks; nothing already published changes.
def fm_question_adds_explanation_only($old):
  def bare: del(.about, .purpose) | .options |= map(del(.detail));
  . as $new
  | ($new | bare) == ($old | bare)
  and all("about", "purpose"; . as $field | $old[$field] == null or $new[$field] == $old[$field])
  and all(range(0; $old.options | length);
    . as $i | $old.options[$i].detail == null or $new.options[$i].detail == $old.options[$i].detail);
def fm_question_normalize:
  {schema,close,options:(.options // []),recommendation:(.recommendation // null),subject:(.subject // null)}
  + (if .about == null then {} else {about} end) + (if .purpose == null then {} else {purpose} end)
  + if .question == null then {} else {question} end;
def fm_question_lifecycle:
  if (.hold_set | fm_question_timestamp) then
    .hold_set + "#" + ([.body_lines[]? | select(test("^Resolution recorded by fm-(captain|decision)-hold\\.$"))] | length | tostring)
  else null end;
def fm_question_context_read:
  . as $row
  | (.body_lines // []) as $lines
  | ($row | fm_question_lifecycle) as $lifecycle
  # Only the active header before the newest resolution can describe this call.
  # Archived contexts below a resolution remain history, never new authority.
  | ([$lines | to_entries[] | select(.value | test("^Resolution recorded by fm-(captain|decision)-hold\\.$")) | .key][0]
      // ($lines | length)) as $header_end
  | [$lines[:$header_end][] | select(startswith("Captain question context:"))] as $markers
  | if ($markers | length) == 0 then {status:"legacy",lifecycle:$lifecycle,context:null}
    elif ($markers | length) != 1 then {status:"duplicate",lifecycle:$lifecycle,context:null}
    elif $lines[1] != $markers[0] or ($markers[0] | length) > 8192 then
      {status:"invalid",lifecycle:$lifecycle,context:null}
    else (try ($markers[0] | ltrimstr("Captain question context: ") | fm_question_json_decode) catch null) as $context
      | if ($context | fm_question_valid(true) | not) then
          {status:"invalid",lifecycle:$lifecycle,context:null}
        elif $context.lifecycle != $lifecycle then {status:"stale",lifecycle:$lifecycle,context:$context}
        else {status:"ready",lifecycle:$lifecycle,context:$context} end
    end;
