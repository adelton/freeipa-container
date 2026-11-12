
def xcontains($element):
	. as $input |
	$element | to_entries | map($input[.key] == .value) | all
;

def unseen:
	[ (.singles | length), (.pairs | length) ]
;

def multiply:
	reduce .[] as $i (1; . * $i)
;

.["build-dist"] as $dist
| (.push.exclude // []) as $nopush
| [(.["fresh-dist"] // []) | .[] | select([ xcontains($nopush[]) ] | any | not)] as $fresh
| (if $fresh | length > 0 then $fresh else $dist end) as $fresh_or_dist
| if $ARGS.named["job"] == "push-data"
then
	[ [ $fresh[].os ] | unique[] | . as $os
		| { "os": $os, "arch": [ $dist | map(select(.os == $os)) | .[] | [ . ] | select(all(contains($nopush[]) | not)) | .[].arch ] } ]
elif $ARGS.named["job"] == "push"
then
	[ $fresh[].os ] | unique
else
.[$ARGS.named.job]
| if . == null then error("Unknown job") end
| ($ARGS.named.count // .count | tonumber) as $count
| (.exclude // []) as $exclude
| .["upgrade-to-from"] as $upgrades

| del(.count, .exclude, .["upgrade-to-from"])
| . as $def

| [
	[ $dist | map(select($upgrades == null or $upgrades[.os])) | map({ dist: . }) ]
		+ [ keys_unsorted[] as $k | [ { $k: .[$k] | keys_unsorted[] } ] ]
	| combinations
	| add
	| { os: .dist.os, arch: .dist.arch } + .
	| if $upgrades then .["data-from"] = $upgrades[.os][] end
]
| map(select([$exclude[] as $e | xcontains($e)] | any | not))

| [ .[]
	| .dist as $d
	| ( [ to_entries[] | [.] | from_entries ] ) as $singles
	| ( [ to_entries[] | select(.key != "dist" or ($fresh_or_dist | any(. == $d))) | [.] | from_entries ] ) as $fresh_singles
	| {
		r: .,
		m: [ to_entries[] | $def[ .key ][ .value ] // 1 ] | multiply,
		singles: $fresh_singles,
		pairs: [ $singles | range(0; length) as $i | range($i + 1; length) as $j | [.[$i], .[$j]] ]
	}
]

| if $count > length then debug("There are only \(length) input records, not \($count)") end
| reduce range([ $count, length ] | min) as $n (.;
	( if $n == 0 then [ range(length) as $i | .[$i] as $r | range($r.m) | $i ]
		else ( .[$n:] | map(unseen) | max ) as $max
			| [ range($n; length) as $i | select((.[$i] | unseen) == $max) | .[$i] as $r | range($r.m) | $i ]
		end ) as $list

	| $list[ now * 1000000 % ($list | length) ] as $selected_index
	| .[$selected_index] as $selected
	| .[$selected_index] = .[$n]
	| .[$n] = $selected
	| .[$n].r.dist as $d
	| if ( $fresh | any(xcontains($d)) ) then .[$n].r["fresh-image"] = true end
	| if ( [ $nopush[] as $np | $d | xcontains($np) ] | any ) then .[$n].r.nopush = true end
	| del(.[$n].r.dist)

	| reduce range($n + 1; length) as $i (.;
		.[$i].singles -= $selected.singles
		| .[$i].pairs -= $selected.pairs
	)
)
| .[:$count]
| map(.r)

# | sort_by(.[])
| sort_by(.os, .arch, .["runs-on"], .kubernetes, .runtime, .readonly, .ca, .volume, .["data-from"])

end
