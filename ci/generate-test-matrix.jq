
def repeat_array($n):
	. as $v | range($n) | $v
;

def frequency_to_list:
	. as $in
	| keys[]
	| . as $k
	| range($in[.] // 1)
	| $k
;

def xcontains($element):
	. as $input |
	$element | to_entries | map($input[.key] == .value) | all
;

# all $k-nuples for an array
def array_subsets($k):
	if $k == 0 then []
	elif length == 0 then empty
	else (.[0] as $h | (.[1:] | array_subsets($k - 1)) as $r | [$h] + $r),
		(.[1:] | array_subsets($k))
	end
;

# all $k-nuples for the record
def object_subsets($k):
	[ to_entries | array_subsets($k) | from_entries ]
;

def random_select($count; $k):
	( [ .out[] | object_subsets($k) ] | add // [] | unique ) as $already_covered
	| .in |= map(.k_subsets = (.data | object_subsets($k)) - $already_covered)
	| .aggregate = ([ .in[].k_subsets ] | add // [] | unique)

	| until( (.out | length) >= $count or (.aggregate | length) == 0 or (.in | length) == 0;
		[ .in[].k_subsets | length ] as $subsets_counts
		| ($subsets_counts | max) as $max
		| ( [ range(0; $subsets_counts | length) | select($subsets_counts[.] == $max) ]
			| .[now * 1000000 % length] ) as $i
		| .in[$i] as $selected
		| .out += [ $selected.data ]
		| .in -= [ $selected ]
		| .in |= map(.k_subsets -= $selected.k_subsets)
		| .aggregate -= $selected.k_subsets
		)
	| if $k < (.in[0].data | length) and (.out | length) < $count
		then random_select($count; $k + 1)
		else .
		end
;

def xcontains_any($element):
	. as $input |
	$element | to_entries | map($input[.key] == .value) | any
;

def random_repeat($e; $count):
	map(select(xcontains_any($e))) as $input |
	($input | length) as $length |
	[
		.[],
		(range($count) | $input[ now * 1000000 % $length ])
	]
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
(if $ARGS.named["count"] != null then $ARGS.named["count"] | tonumber else .[ $ARGS.named["job"] ].count end) as $count
| if $ARGS.named["job"] == "run"
then
	.run as { "runs-on": $runson, $runtime, $readonly, $ca, $volume, $exclude }
	| [
		[ {
		"os": null, "arch": null,
		"dist": ($fresh | repeat_array(3), $dist)[],
		"runtime": $runtime | frequency_to_list,
		"readonly": $readonly | frequency_to_list,
		"ca": $ca | frequency_to_list,
		"volume": $volume | frequency_to_list,
		"runs-on": $runson | frequency_to_list
		}
		| . += .dist
		],
		$exclude
	]
elif $ARGS.named["job"] == "test-upgrade"
then
	.["test-upgrade"] as { "runs-on": $runson, $runtime, $volume, "upgrade-to-from": $upgrade, $exclude }
	| [
		[ {
		"os": null, "arch": null,
		"dist": (($fresh | repeat_array(3), $dist) | .[] | select($upgrade[.os])),
		"runtime": $runtime | frequency_to_list,
		"volume": $volume | frequency_to_list,
		"runs-on": $runson | frequency_to_list
		}
		| . += .dist
		| .["data-from"] = $upgrade[.os][]
		],
		$exclude
	]
elif $ARGS.named["job"] == "k8s"
then
	.k8s as { "runs-on": $runson, $kubernetes, $runtime, $exclude }
	| [
		[ {
		"os": null, "arch": null,
		"dist": ($fresh | repeat_array(3), $dist)[],
		"kubernetes": $kubernetes | frequency_to_list,
		"runtime": $runtime | frequency_to_list,
		"runs-on": $runson | frequency_to_list
		}
		| . += .dist
		],
		$exclude
	]
else
	error("Unknown job")
end

| ( .[1] // [] ) as $exclude
| reduce $exclude[] as $e (.[0];
	map(select(xcontains($e))) as $remove
	| map(select(xcontains($e) | not))
	| random_repeat($e; $remove | length)
	)
| { in: map({data: .}), out: [] }
| random_select($count; 1)
| [ .out[]
	| .dist as $d
	| if ( $fresh | any(xcontains($d)) ) then .["fresh-image"] = true end
	| if ( $nopush | any(xcontains($d)) ) then .["nopush"] = true end
	| del(.dist)
]
| sort_by(.os, .arch, .["runs-on"], .kubernetes, .runtime, .readonly, .ca, .volume, .["data-from"])

end

