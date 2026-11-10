def signed_labels:
  if has("labels") then
    ([ (.labels // [])[] | select(.signing == true or .signing == "true")
       | {name, version, value, signing} | with_entries(select(.value != null)) ]) as $l
    | if $l == [] then del(.labels) else .labels = $l end
  else . end;
.[0]
| del(.meta, .signatures, .nestedDigests)
| .component |= (
    del(.repositoryContexts)
    | .provider |= (if type == "string" then {name: .} else . end)
    | signed_labels
    | .resources = [ (.resources // [])[]
        | if (.access.type? // "") == "none" or (.access.type? // "") == "None" then del(.digest) else . end
        | del(.access, .srcRefs) | signed_labels ]
    | .sources = [ (.sources // [])[] | del(.access) | signed_labels ]
    | .componentReferences = [ (.componentReferences // [])[] | signed_labels ] )
