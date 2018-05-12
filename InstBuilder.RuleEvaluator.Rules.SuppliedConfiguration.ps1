rule -Individual /Configuration/AlternateName `
     -Script {
  if ($nodeValue.Length -ne 0) {
    throw "A configuration constructed in this context may define no AlternateName"
  }

  $node.$valProp = "n/a"
}
rule -Individual /Configuration/Alternates `
     -Script {
  if ($nodeValue.Length -ne 0) {
    throw "A configuration constructed in this context may define no Alternates"
  }

  $node.$valProp = "n/a"
}