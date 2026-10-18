# Rules shared by rollout.sh and publish-sheet.sh (README.md, "The signed channel sheet").
# valid_payload is the client's Sheet::check (updated/channel-sheet in NyraOS/nyra-base) plus the channel
# binding; keep them in step.

def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
def vkey: split(".") | map(tonumber);
def digest: type == "string" and test("^sha256:[a-f0-9]{64}$");
def count: type == "number" and . == floor and . >= 0;

# releases.json: {"<version>": "<digest>"}, one digest per version and one version per digest.
def valid_releases:
  type == "object" and (keys | all(version)) and ([.[]] | all(digest))
  and ([.[]] | length) == ([.[]] | unique | length);

# A channel file (channels/<repo>/<channel>.json), versions only:
# {"current": "2026.10.3", "previous": "2026.10.1", "percent": 25, "halted": false, "retracted": ["2026.10.2"]}
def valid_state($releases):
  type == "object" and (keys == ["current", "halted", "percent", "previous", "retracted"])
  and (.current | version and $releases[.] != null)
  and (.previous == null or ((.previous | version and $releases[.] != null) and (.previous | vkey) < (.current | vkey)))
  and (.percent | count and . <= 100) and (.halted | type == "boolean")
  and (.previous != null or (.percent == 100 and (.halted | not)))
  and (.retracted | type == "array" and all(version and $releases[.] != null))
  and ([.current, .previous] as $served | all(.retracted[]; . as $v | $served | index($v) | not));

# The signed payload.
def valid_payload($repo; $channel):
  def image: type == "object" and (keys == ["digest", "version"]) and (.digest | digest) and (.version | version);
  type == "object" and .schema == 1 and .repository == $repo and .channel == $channel
  and (.sequence | count) and (.issued_at | count) and (.expires_at | count)
  and .expires_at > .issued_at and .expires_at - .issued_at <= 31 * 86400 and .sequence <= .expires_at
  and (.current | image)
  and (.previous == null or ((.previous | image) and .previous.digest != .current.digest
       and (.previous.version | vkey) < (.current.version | vkey)))
  and (.percent | count and . <= 100) and (.halted | type == "boolean")
  and (.previous != null or (.percent == 100 and (.halted | not)))
  and (.retracted | type == "array" and all(digest))
  and ([.current.digest, .previous.digest] as $served | all(.retracted[]; . as $d | $served | index($d) | not));
