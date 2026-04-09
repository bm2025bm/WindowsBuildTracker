<#
.SYNOPSIS
    Reports Windows cumulative-update currency into NinjaRMM custom fields.

.DESCRIPTION
    Detects the installed Windows build, resolves it against an authoritative
    build database (windows-builds.json) fetched from WindowsBuildTracker,
    computes how many months behind the latest available patch for that build
    family this machine is, and writes the result into NinjaRMM custom fields.

    Data source: https://github.com/bm2025bm/WindowsBuildTracker
    (refreshed weekly from learn.microsoft.com/windows/release-health)

    Custom fields written (all must exist in NinjaRMM before deployment):
      - windowscumulativeupdatedate          (text)     e.g. "2025.10" or "2025.10-Preview" / "-OOB", empty on non-OK status
      - windowscumulativeupdatedifference    (integer)  <=0, empty on non-OK status
      - windowscumulativeupdateversion       (text)     full build e.g. "26100.6899"
      - windowscumulativeupdatedatacollected (datetime) unix timestamp
      - windowscumulativeupdatestatus        (text)     OK | UnknownBuild | Insider | NetworkError | ScriptError

    Invariant: the date and difference fields are either valid data or empty.
    Dashboards should filter on status = OK before computing compliance.
#>
#Requires -Version 3.0
[CmdletBinding()]
Param(
    [string]$DataUrl = 'https://raw.githubusercontent.com/bm2025bm/WindowsBuildTracker/main/windows-builds.json',
    [string]$CacheDir = '',
    [int]$CacheMaxAgeHours = 24,
    [int]$FallbackMaxAgeDays = 90
)

$ScriptVersion = '1.0.6'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Force TLS 1.2 — older systems (PS 4 / Server 2012 / Win 7) default to
# SSL3/TLS1.0, which GitHub rejects. Use bitwise-or so we don't downgrade
# anything that's already enabled.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Embedded last-known-good database. Regenerated at release time from the
# repo's windows-builds.json. Used only when both the network fetch and the
# local cache are unavailable.
$FallbackJson = @'
{"updatedAt":"2026-04-09T06:30:45Z","source":"learn.microsoft.com/windows/release-health (embedded subset)","buildCount":271,"builds":[{"build":"14393.6709","major":14393,"year":2024,"month":2,"type":"Standard","kb":"KB5034767"},{"build":"14393.6796","major":14393,"year":2024,"month":3,"type":"Standard","kb":"KB5035855"},{"build":"14393.6800","major":14393,"year":2024,"month":3,"type":"OOB","kb":"KB5037423"},{"build":"14393.6897","major":14393,"year":2024,"month":4,"type":"Standard","kb":"KB5036899"},{"build":"14393.6981","major":14393,"year":2024,"month":5,"type":"Standard","kb":"KB5037763"},{"build":"14393.7070","major":14393,"year":2024,"month":6,"type":"Standard","kb":"KB5039214"},{"build":"14393.7159","major":14393,"year":2024,"month":7,"type":"Standard","kb":"KB5040434"},{"build":"14393.7259","major":14393,"year":2024,"month":8,"type":"Standard","kb":"KB5041773"},{"build":"14393.7336","major":14393,"year":2024,"month":9,"type":"Standard","kb":"KB5043051"},{"build":"14393.7428","major":14393,"year":2024,"month":10,"type":"Standard","kb":"KB5044293"},{"build":"14393.7515","major":14393,"year":2024,"month":11,"type":"Standard","kb":"KB5046612"},{"build":"14393.7606","major":14393,"year":2024,"month":12,"type":"Standard","kb":"KB5048671"},{"build":"14393.7699","major":14393,"year":2025,"month":1,"type":"Standard","kb":"KB5049993"},{"build":"14393.7785","major":14393,"year":2025,"month":2,"type":"Standard","kb":"KB5052006"},{"build":"14393.7876","major":14393,"year":2025,"month":3,"type":"Standard","kb":"KB5053594"},{"build":"14393.7969","major":14393,"year":2025,"month":4,"type":"Standard","kb":"KB5055521"},{"build":"14393.7973","major":14393,"year":2025,"month":4,"type":"OOB","kb":"KB5058921"},{"build":"14393.8066","major":14393,"year":2025,"month":5,"type":"Standard","kb":"KB5058383"},{"build":"14393.8148","major":14393,"year":2025,"month":6,"type":"Standard","kb":"KB5061010"},{"build":"14393.8246","major":14393,"year":2025,"month":7,"type":"Standard","kb":"KB5062560"},{"build":"14393.8330","major":14393,"year":2025,"month":8,"type":"Standard","kb":"KB5063871"},{"build":"14393.8422","major":14393,"year":2025,"month":9,"type":"Standard","kb":"KB5065427"},{"build":"14393.8519","major":14393,"year":2025,"month":10,"type":"Standard","kb":"KB5066836"},{"build":"14393.8524","major":14393,"year":2025,"month":10,"type":"OOB","kb":"KB5070882"},{"build":"14393.8594","major":14393,"year":2025,"month":11,"type":"Standard","kb":"KB5068864"},{"build":"14393.8688","major":14393,"year":2025,"month":12,"type":"Standard","kb":"KB5071543"},{"build":"14393.8692","major":14393,"year":2025,"month":12,"type":"OOB","kb":"KB5074974"},{"build":"14393.8783","major":14393,"year":2026,"month":1,"type":"Standard","kb":"KB5073722"},{"build":"14393.8868","major":14393,"year":2026,"month":2,"type":"Standard","kb":"KB5075999"},{"build":"14393.8957","major":14393,"year":2026,"month":3,"type":"Standard","kb":"KB5078938"},{"build":"17763.5936","major":17763,"year":2024,"month":6,"type":"Standard","kb":"KB5039217"},{"build":"17763.6054","major":17763,"year":2024,"month":7,"type":"Standard","kb":"KB5040430"},{"build":"17763.6189","major":17763,"year":2024,"month":8,"type":"Standard","kb":"KB5041578"},{"build":"17763.6293","major":17763,"year":2024,"month":9,"type":"Standard","kb":"KB5043050"},{"build":"17763.6414","major":17763,"year":2024,"month":10,"type":"Standard","kb":"KB5044277"},{"build":"17763.6532","major":17763,"year":2024,"month":11,"type":"Standard","kb":"KB5046615"},{"build":"17763.6659","major":17763,"year":2024,"month":12,"type":"Standard","kb":"KB5048661"},{"build":"17763.6775","major":17763,"year":2025,"month":1,"type":"Standard","kb":"KB5050008"},{"build":"17763.6893","major":17763,"year":2025,"month":2,"type":"Standard","kb":"KB5052000"},{"build":"17763.7009","major":17763,"year":2025,"month":3,"type":"Standard","kb":"KB5053596"},{"build":"17763.7136","major":17763,"year":2025,"month":4,"type":"Standard","kb":"KB5055519"},{"build":"17763.7240","major":17763,"year":2025,"month":4,"type":"OOB","kb":"KB5058922"},{"build":"17763.7249","major":17763,"year":2025,"month":4,"type":"OOB","kb":"KB5059091"},{"build":"17763.7314","major":17763,"year":2025,"month":5,"type":"Standard","kb":"KB5058392"},{"build":"17763.7322","major":17763,"year":2025,"month":5,"type":"OOB","kb":"KB5061978"},{"build":"17763.7434","major":17763,"year":2025,"month":6,"type":"Standard","kb":"KB5060531"},{"build":"17763.7558","major":17763,"year":2025,"month":7,"type":"Standard","kb":"KB5062557"},{"build":"17763.7678","major":17763,"year":2025,"month":8,"type":"Standard","kb":"KB5063877"},{"build":"17763.7683","major":17763,"year":2025,"month":8,"type":"OOB","kb":"KB5066187"},{"build":"17763.7792","major":17763,"year":2025,"month":9,"type":"Standard","kb":"KB5065428"},{"build":"17763.7919","major":17763,"year":2025,"month":10,"type":"Standard","kb":"KB5066586"},{"build":"17763.7922","major":17763,"year":2025,"month":10,"type":"OOB","kb":"KB5070883"},{"build":"17763.8027","major":17763,"year":2025,"month":11,"type":"Standard","kb":"KB5068791"},{"build":"17763.8146","major":17763,"year":2025,"month":12,"type":"Standard","kb":"KB5071544"},{"build":"17763.8148","major":17763,"year":2025,"month":12,"type":"OOB","kb":"KB5074975"},{"build":"17763.8276","major":17763,"year":2026,"month":1,"type":"Standard","kb":"KB5073723"},{"build":"17763.8280","major":17763,"year":2026,"month":1,"type":"OOB","kb":"KB5077795"},{"build":"17763.8281","major":17763,"year":2026,"month":1,"type":"OOB","kb":"KB5078131"},{"build":"17763.8389","major":17763,"year":2026,"month":2,"type":"Standard","kb":"KB5075904"},{"build":"17763.8511","major":17763,"year":2026,"month":3,"type":"Standard","kb":"KB5078752"},{"build":"19044.4291","major":19044,"year":2024,"month":4,"type":"Standard","kb":"KB5036892"},{"build":"19044.4412","major":19044,"year":2024,"month":5,"type":"Standard","kb":"KB5037768"},{"build":"19044.4529","major":19044,"year":2024,"month":6,"type":"Standard","kb":"KB5039211"},{"build":"19044.4651","major":19044,"year":2024,"month":7,"type":"Standard","kb":"KB5040427"},{"build":"19044.4780","major":19044,"year":2024,"month":8,"type":"Standard","kb":"KB5041580"},{"build":"19044.4894","major":19044,"year":2024,"month":9,"type":"Standard","kb":"KB5043064"},{"build":"19044.5011","major":19044,"year":2024,"month":10,"type":"Standard","kb":"KB5044273"},{"build":"19044.5131","major":19044,"year":2024,"month":11,"type":"Standard","kb":"KB5046613"},{"build":"19044.5247","major":19044,"year":2024,"month":12,"type":"Standard","kb":"KB5048652"},{"build":"19044.5371","major":19044,"year":2025,"month":1,"type":"Standard","kb":"KB5049981"},{"build":"19044.5487","major":19044,"year":2025,"month":2,"type":"Standard","kb":"KB5051974"},{"build":"19044.5608","major":19044,"year":2025,"month":3,"type":"Standard","kb":"KB5053606"},{"build":"19044.5737","major":19044,"year":2025,"month":4,"type":"Standard","kb":"KB5055518"},{"build":"19044.5854","major":19044,"year":2025,"month":5,"type":"Standard","kb":"KB5058379"},{"build":"19044.5856","major":19044,"year":2025,"month":5,"type":"OOB","kb":"KB5061768"},{"build":"19044.5859","major":19044,"year":2025,"month":5,"type":"OOB","kb":"KB5061979"},{"build":"19044.5965","major":19044,"year":2025,"month":6,"type":"Standard","kb":"KB5060533"},{"build":"19044.6093","major":19044,"year":2025,"month":7,"type":"Standard","kb":"KB5062554"},{"build":"19044.6216","major":19044,"year":2025,"month":8,"type":"Standard","kb":"KB5063709"},{"build":"19044.6218","major":19044,"year":2025,"month":8,"type":"OOB","kb":"KB5066188"},{"build":"19044.6332","major":19044,"year":2025,"month":9,"type":"Standard","kb":"KB5065429"},{"build":"19044.6456","major":19044,"year":2025,"month":10,"type":"Standard","kb":"KB5066791"},{"build":"19044.6575","major":19044,"year":2025,"month":11,"type":"Standard","kb":"KB5068781"},{"build":"19044.6691","major":19044,"year":2025,"month":12,"type":"Standard","kb":"KB5071546"},{"build":"19044.6693","major":19044,"year":2025,"month":12,"type":"OOB","kb":"KB5074976"},{"build":"19044.6809","major":19044,"year":2026,"month":1,"type":"Standard","kb":"KB5073724"},{"build":"19044.6811","major":19044,"year":2026,"month":1,"type":"OOB","kb":"KB5077796"},{"build":"19044.6812","major":19044,"year":2026,"month":1,"type":"OOB","kb":"KB5078129"},{"build":"19044.6937","major":19044,"year":2026,"month":2,"type":"Standard","kb":"KB5075912"},{"build":"19044.7058","major":19044,"year":2026,"month":3,"type":"Standard","kb":"KB5078885"},{"build":"19045.5487","major":19045,"year":2025,"month":2,"type":"Standard","kb":"KB5051974"},{"build":"19045.5555","major":19045,"year":2025,"month":2,"type":"Preview","kb":"KB5052077"},{"build":"19045.5608","major":19045,"year":2025,"month":3,"type":"Standard","kb":"KB5053606"},{"build":"19045.5679","major":19045,"year":2025,"month":3,"type":"Preview","kb":"KB5053643"},{"build":"19045.5737","major":19045,"year":2025,"month":4,"type":"Standard","kb":"KB5055518"},{"build":"19045.5796","major":19045,"year":2025,"month":4,"type":"Preview","kb":"KB5055612"},{"build":"19045.5854","major":19045,"year":2025,"month":5,"type":"Standard","kb":"KB5058379"},{"build":"19045.5856","major":19045,"year":2025,"month":5,"type":"OOB","kb":"KB5061768"},{"build":"19045.5859","major":19045,"year":2025,"month":5,"type":"OOB","kb":"KB5061979"},{"build":"19045.5917","major":19045,"year":2025,"month":5,"type":"Preview","kb":"KB5058481"},{"build":"19045.5965","major":19045,"year":2025,"month":6,"type":"Standard","kb":"KB5060533"},{"build":"19045.5968","major":19045,"year":2025,"month":6,"type":"OOB","kb":"KB5063159"},{"build":"19045.6036","major":19045,"year":2025,"month":6,"type":"Preview","kb":"KB5061087"},{"build":"19045.6093","major":19045,"year":2025,"month":7,"type":"Standard","kb":"KB5062554"},{"build":"19045.6159","major":19045,"year":2025,"month":7,"type":"Preview","kb":"KB5062649"},{"build":"19045.6216","major":19045,"year":2025,"month":8,"type":"Standard","kb":"KB5063709"},{"build":"19045.6218","major":19045,"year":2025,"month":8,"type":"OOB","kb":"KB5066188"},{"build":"19045.6282","major":19045,"year":2025,"month":8,"type":"Preview","kb":"KB5063842"},{"build":"19045.6332","major":19045,"year":2025,"month":9,"type":"Standard","kb":"KB5065429"},{"build":"19045.6396","major":19045,"year":2025,"month":9,"type":"Preview","kb":"KB5066198"},{"build":"19045.6456","major":19045,"year":2025,"month":10,"type":"Standard","kb":"KB5066791"},{"build":"19045.6466","major":19045,"year":2025,"month":11,"type":"OOB","kb":"KB5071959"},{"build":"19045.6575","major":19045,"year":2025,"month":11,"type":"Standard","kb":"KB5068781"},{"build":"19045.6691","major":19045,"year":2025,"month":12,"type":"Standard","kb":"KB5071546"},{"build":"19045.6693","major":19045,"year":2025,"month":12,"type":"OOB","kb":"KB5074976"},{"build":"19045.6809","major":19045,"year":2026,"month":1,"type":"Standard","kb":"KB5073724"},{"build":"19045.6811","major":19045,"year":2026,"month":1,"type":"OOB","kb":"KB5077796"},{"build":"19045.6812","major":19045,"year":2026,"month":1,"type":"OOB","kb":"KB5078129"},{"build":"19045.6937","major":19045,"year":2026,"month":2,"type":"Standard","kb":"KB5075912"},{"build":"19045.7058","major":19045,"year":2026,"month":3,"type":"Standard","kb":"KB5078885"},{"build":"20348.3207","major":20348,"year":2025,"month":2,"type":"Standard","kb":"KB5051979"},{"build":"20348.3270","major":20348,"year":2025,"month":3,"type":"Standard","kb":"KB5053638"},{"build":"20348.3328","major":20348,"year":2025,"month":3,"type":"Standard","kb":"KB5053603"},{"build":"20348.3453","major":20348,"year":2025,"month":4,"type":"Standard","kb":"KB5055526"},{"build":"20348.3561","major":20348,"year":2025,"month":4,"type":"OOB","kb":"KB5058920"},{"build":"20348.3566","major":20348,"year":2025,"month":4,"type":"OOB","kb":"KB5059092"},{"build":"20348.3630","major":20348,"year":2025,"month":5,"type":"Standard","kb":"KB5058500"},{"build":"20348.3692","major":20348,"year":2025,"month":5,"type":"Standard","kb":"KB5058385"},{"build":"20348.3695","major":20348,"year":2025,"month":5,"type":"OOB","kb":"KB5061906"},{"build":"20348.3745","major":20348,"year":2025,"month":6,"type":"Standard","kb":"KB5060525"},{"build":"20348.3807","major":20348,"year":2025,"month":6,"type":"Standard","kb":"KB5060526"},{"build":"20348.3932","major":20348,"year":2025,"month":7,"type":"Standard","kb":"KB5062572"},{"build":"20348.3989","major":20348,"year":2025,"month":8,"type":"Standard","kb":"KB5063812"},{"build":"20348.4052","major":20348,"year":2025,"month":8,"type":"Standard","kb":"KB5063880"},{"build":"20348.4106","major":20348,"year":2025,"month":9,"type":"Standard","kb":"KB5065306"},{"build":"20348.4171","major":20348,"year":2025,"month":9,"type":"Standard","kb":"KB5065432"},{"build":"20348.4294","major":20348,"year":2025,"month":10,"type":"Standard","kb":"KB5066782"},{"build":"20348.4297","major":20348,"year":2025,"month":10,"type":"OOB","kb":"KB5070884"},{"build":"20348.4346","major":20348,"year":2025,"month":11,"type":"Standard","kb":"KB5068840"},{"build":"20348.4405","major":20348,"year":2025,"month":11,"type":"Standard","kb":"KB5068787"},{"build":"20348.4467","major":20348,"year":2025,"month":12,"type":"Standard","kb":"KB5071413"},{"build":"20348.4529","major":20348,"year":2025,"month":12,"type":"Standard","kb":"KB5071547"},{"build":"20348.4648","major":20348,"year":2026,"month":1,"type":"Standard","kb":"KB5073457"},{"build":"20348.4650","major":20348,"year":2026,"month":1,"type":"OOB","kb":"KB5077800"},{"build":"20348.4651","major":20348,"year":2026,"month":1,"type":"OOB","kb":"KB5078136"},{"build":"20348.4711","major":20348,"year":2026,"month":2,"type":"Standard","kb":"KB5075943"},{"build":"20348.4773","major":20348,"year":2026,"month":2,"type":"Standard","kb":"KB5075906"},{"build":"20348.4776","major":20348,"year":2026,"month":3,"type":"OOB","kb":"KB5082314"},{"build":"20348.4830","major":20348,"year":2026,"month":3,"type":"Standard","kb":"KB5078737"},{"build":"20348.4893","major":20348,"year":2026,"month":3,"type":"Standard","kb":"KB5078766"},{"build":"22000.2713","major":22000,"year":2024,"month":1,"type":"Standard","kb":"KB5034121"},{"build":"22000.2777","major":22000,"year":2024,"month":2,"type":"Standard","kb":"KB5034766"},{"build":"22000.2836","major":22000,"year":2024,"month":3,"type":"Standard","kb":"KB5035854"},{"build":"22000.2899","major":22000,"year":2024,"month":4,"type":"Standard","kb":"KB5036894"},{"build":"22000.2960","major":22000,"year":2024,"month":5,"type":"Standard","kb":"KB5037770"},{"build":"22000.3019","major":22000,"year":2024,"month":6,"type":"Standard","kb":"KB5039213"},{"build":"22000.3079","major":22000,"year":2024,"month":7,"type":"Standard","kb":"KB5040431"},{"build":"22000.3147","major":22000,"year":2024,"month":8,"type":"Standard","kb":"KB5041592"},{"build":"22000.3197","major":22000,"year":2024,"month":9,"type":"Standard","kb":"KB5043067"},{"build":"22000.3260","major":22000,"year":2024,"month":10,"type":"Standard","kb":"KB5044280"},{"build":"22621.3880","major":22621,"year":2024,"month":7,"type":"Standard","kb":"KB5040442"},{"build":"22621.3958","major":22621,"year":2024,"month":7,"type":"Preview","kb":"KB5040527"},{"build":"22621.4037","major":22621,"year":2024,"month":8,"type":"Standard","kb":"KB5041585"},{"build":"22621.4112","major":22621,"year":2024,"month":8,"type":"Preview","kb":"KB5041587"},{"build":"22621.4169","major":22621,"year":2024,"month":9,"type":"Standard","kb":"KB5043076"},{"build":"22621.4249","major":22621,"year":2024,"month":9,"type":"Preview","kb":"KB5043145"},{"build":"22621.4317","major":22621,"year":2024,"month":10,"type":"Standard","kb":"KB5044285"},{"build":"22621.4391","major":22621,"year":2024,"month":10,"type":"Preview","kb":"KB5044380"},{"build":"22621.4460","major":22621,"year":2024,"month":11,"type":"Standard","kb":"KB5046633"},{"build":"22621.4541","major":22621,"year":2024,"month":11,"type":"Preview","kb":"KB5046732"},{"build":"22621.4602","major":22621,"year":2024,"month":12,"type":"Standard","kb":"KB5048685"},{"build":"22621.4751","major":22621,"year":2025,"month":1,"type":"Standard","kb":"KB5050021"},{"build":"22621.4830","major":22621,"year":2025,"month":1,"type":"Preview","kb":"KB5050092"},{"build":"22621.4890","major":22621,"year":2025,"month":2,"type":"Standard","kb":"KB5051989"},{"build":"22621.4974","major":22621,"year":2025,"month":2,"type":"Preview","kb":"KB5052094"},{"build":"22621.5039","major":22621,"year":2025,"month":3,"type":"Standard","kb":"KB5053602"},{"build":"22621.5126","major":22621,"year":2025,"month":3,"type":"Preview","kb":"KB5053657"},{"build":"22621.5189","major":22621,"year":2025,"month":4,"type":"Standard","kb":"KB5055528"},{"build":"22621.5192","major":22621,"year":2025,"month":4,"type":"OOB","kb":"KB5058919"},{"build":"22621.5262","major":22621,"year":2025,"month":4,"type":"Preview","kb":"KB5055629"},{"build":"22621.5335","major":22621,"year":2025,"month":5,"type":"Standard","kb":"KB5058405"},{"build":"22621.5413","major":22621,"year":2025,"month":5,"type":"Preview","kb":"KB5058502"},{"build":"22621.5415","major":22621,"year":2025,"month":5,"type":"OOB","kb":"KB5062170"},{"build":"22621.5472","major":22621,"year":2025,"month":6,"type":"Standard","kb":"KB5060999"},{"build":"22621.5549","major":22621,"year":2025,"month":6,"type":"Preview","kb":"KB5060826"},{"build":"22621.5624","major":22621,"year":2025,"month":7,"type":"Standard","kb":"KB5062552"},{"build":"22621.5768","major":22621,"year":2025,"month":8,"type":"Standard","kb":"KB5063875"},{"build":"22621.5771","major":22621,"year":2025,"month":8,"type":"OOB","kb":"KB5066189"},{"build":"22621.5909","major":22621,"year":2025,"month":9,"type":"Standard","kb":"KB5065431"},{"build":"22621.6060","major":22621,"year":2025,"month":10,"type":"Standard","kb":"KB5066793"},{"build":"22631.4830","major":22631,"year":2025,"month":1,"type":"Preview","kb":"KB5050092"},{"build":"22631.4890","major":22631,"year":2025,"month":2,"type":"Standard","kb":"KB5051989"},{"build":"22631.4974","major":22631,"year":2025,"month":2,"type":"Preview","kb":"KB5052094"},{"build":"22631.5039","major":22631,"year":2025,"month":3,"type":"Standard","kb":"KB5053602"},{"build":"22631.5126","major":22631,"year":2025,"month":3,"type":"Preview","kb":"KB5053657"},{"build":"22631.5189","major":22631,"year":2025,"month":4,"type":"Standard","kb":"KB5055528"},{"build":"22631.5192","major":22631,"year":2025,"month":4,"type":"OOB","kb":"KB5058919"},{"build":"22631.5262","major":22631,"year":2025,"month":4,"type":"Preview","kb":"KB5055629"},{"build":"22631.5335","major":22631,"year":2025,"month":5,"type":"Standard","kb":"KB5058405"},{"build":"22631.5413","major":22631,"year":2025,"month":5,"type":"Preview","kb":"KB5058502"},{"build":"22631.5415","major":22631,"year":2025,"month":5,"type":"OOB","kb":"KB5062170"},{"build":"22631.5472","major":22631,"year":2025,"month":6,"type":"Standard","kb":"KB5060999"},{"build":"22631.5549","major":22631,"year":2025,"month":6,"type":"Preview","kb":"KB5060826"},{"build":"22631.5624","major":22631,"year":2025,"month":7,"type":"Standard","kb":"KB5062552"},{"build":"22631.5699","major":22631,"year":2025,"month":7,"type":"Preview","kb":"KB5062663"},{"build":"22631.5768","major":22631,"year":2025,"month":8,"type":"Standard","kb":"KB5063875"},{"build":"22631.5771","major":22631,"year":2025,"month":8,"type":"OOB","kb":"KB5066189"},{"build":"22631.5840","major":22631,"year":2025,"month":8,"type":"Preview","kb":"KB5064080"},{"build":"22631.5909","major":22631,"year":2025,"month":9,"type":"Standard","kb":"KB5065431"},{"build":"22631.5984","major":22631,"year":2025,"month":9,"type":"Preview","kb":"KB5065790"},{"build":"22631.6060","major":22631,"year":2025,"month":10,"type":"Standard","kb":"KB5066793"},{"build":"22631.6133","major":22631,"year":2025,"month":10,"type":"Preview","kb":"KB5067112"},{"build":"22631.6199","major":22631,"year":2025,"month":11,"type":"Standard","kb":"KB5068865"},{"build":"22631.6276","major":22631,"year":2025,"month":11,"type":"Preview","kb":"KB5070312"},{"build":"22631.6345","major":22631,"year":2025,"month":12,"type":"Standard","kb":"KB5071417"},{"build":"22631.6491","major":22631,"year":2026,"month":1,"type":"Standard","kb":"KB5073455"},{"build":"22631.6494","major":22631,"year":2026,"month":1,"type":"OOB","kb":"KB5077797"},{"build":"22631.6495","major":22631,"year":2026,"month":1,"type":"OOB","kb":"KB5078132"},{"build":"22631.6649","major":22631,"year":2026,"month":2,"type":"Standard","kb":"KB5075941"},{"build":"22631.6783","major":22631,"year":2026,"month":3,"type":"Standard","kb":"KB5078883"},{"build":"26100.32230","major":26100,"year":2026,"month":1,"type":"Standard","kb":"KB5073379"},{"build":"26100.32234","major":26100,"year":2026,"month":1,"type":"OOB","kb":"KB5077793"},{"build":"26100.32236","major":26100,"year":2026,"month":1,"type":"OOB","kb":"KB5078135"},{"build":"26100.32313","major":26100,"year":2026,"month":2,"type":"Standard","kb":"KB5075942"},{"build":"26100.32370","major":26100,"year":2026,"month":2,"type":"Standard","kb":"KB5075899"},{"build":"26100.32463","major":26100,"year":2026,"month":3,"type":"Standard","kb":"KB5078736"},{"build":"26100.32522","major":26100,"year":2026,"month":3,"type":"Standard","kb":"KB5078740"},{"build":"26100.6725","major":26100,"year":2025,"month":9,"type":"Preview","kb":"KB5065789"},{"build":"26100.6899","major":26100,"year":2025,"month":10,"type":"Standard","kb":"KB5066835"},{"build":"26100.6901","major":26100,"year":2025,"month":10,"type":"OOB","kb":"KB5070773"},{"build":"26100.6905","major":26100,"year":2025,"month":10,"type":"OOB","kb":"KB5070881"},{"build":"26100.7019","major":26100,"year":2025,"month":10,"type":"Preview","kb":"KB5067036"},{"build":"26100.7092","major":26100,"year":2025,"month":11,"type":"Standard","kb":"KB5068966"},{"build":"26100.7171","major":26100,"year":2025,"month":11,"type":"Standard","kb":"KB5068861"},{"build":"26100.7178","major":26100,"year":2025,"month":11,"type":"OOB","kb":"KB5072359"},{"build":"26100.7309","major":26100,"year":2025,"month":12,"type":"Preview","kb":"KB5070311"},{"build":"26100.7392","major":26100,"year":2025,"month":12,"type":"Standard","kb":"KB5072014"},{"build":"26100.7462","major":26100,"year":2025,"month":12,"type":"Standard","kb":"KB5072033"},{"build":"26100.7623","major":26100,"year":2026,"month":1,"type":"Standard","kb":"KB5074109"},{"build":"26100.7627","major":26100,"year":2026,"month":1,"type":"OOB","kb":"KB5077744"},{"build":"26100.7628","major":26100,"year":2026,"month":1,"type":"OOB","kb":"KB5078127"},{"build":"26100.7705","major":26100,"year":2026,"month":1,"type":"Preview","kb":"KB5074105"},{"build":"26100.7781","major":26100,"year":2026,"month":2,"type":"Standard","kb":"KB5077212"},{"build":"26100.7840","major":26100,"year":2026,"month":2,"type":"Standard","kb":"KB5077181"},{"build":"26100.7922","major":26100,"year":2026,"month":2,"type":"Preview","kb":"KB5077241"},{"build":"26100.7979","major":26100,"year":2026,"month":3,"type":"Standard","kb":"KB5079420"},{"build":"26100.8037","major":26100,"year":2026,"month":3,"type":"Standard","kb":"KB5079473"},{"build":"26100.8039","major":26100,"year":2026,"month":3,"type":"OOB","kb":"KB5085516"},{"build":"26100.8116","major":26100,"year":2026,"month":3,"type":"Preview","kb":"KB5079391"},{"build":"26100.8117","major":26100,"year":2026,"month":3,"type":"OOB","kb":"KB5086672"},{"build":"26200.6584","major":26200,"year":2025,"month":9,"type":"Standard","kb":""},{"build":"26200.6899","major":26200,"year":2025,"month":10,"type":"Standard","kb":"KB5066835"},{"build":"26200.6901","major":26200,"year":2025,"month":10,"type":"OOB","kb":"KB5070773"},{"build":"26200.7019","major":26200,"year":2025,"month":10,"type":"Preview","kb":"KB5067036"},{"build":"26200.7092","major":26200,"year":2025,"month":11,"type":"Standard","kb":"KB5068966"},{"build":"26200.7171","major":26200,"year":2025,"month":11,"type":"Standard","kb":"KB5068861"},{"build":"26200.7309","major":26200,"year":2025,"month":12,"type":"Preview","kb":"KB5070311"},{"build":"26200.7392","major":26200,"year":2025,"month":12,"type":"Standard","kb":"KB5072014"},{"build":"26200.7462","major":26200,"year":2025,"month":12,"type":"Standard","kb":"KB5072033"},{"build":"26200.7623","major":26200,"year":2026,"month":1,"type":"Standard","kb":"KB5074109"},{"build":"26200.7627","major":26200,"year":2026,"month":1,"type":"OOB","kb":"KB5077744"},{"build":"26200.7628","major":26200,"year":2026,"month":1,"type":"OOB","kb":"KB5078127"},{"build":"26200.7705","major":26200,"year":2026,"month":1,"type":"Preview","kb":"KB5074105"},{"build":"26200.7781","major":26200,"year":2026,"month":2,"type":"Standard","kb":"KB5077212"},{"build":"26200.7840","major":26200,"year":2026,"month":2,"type":"Standard","kb":"KB5077181"},{"build":"26200.7922","major":26200,"year":2026,"month":2,"type":"Preview","kb":"KB5077241"},{"build":"26200.7979","major":26200,"year":2026,"month":3,"type":"Standard","kb":"KB5079420"},{"build":"26200.8037","major":26200,"year":2026,"month":3,"type":"Standard","kb":"KB5079473"},{"build":"26200.8039","major":26200,"year":2026,"month":3,"type":"OOB","kb":"KB5085516"},{"build":"26200.8116","major":26200,"year":2026,"month":3,"type":"Preview","kb":"KB5079391"},{"build":"26200.8117","major":26200,"year":2026,"month":3,"type":"OOB","kb":"KB5086672"}]}
'@

# ---------------------------------------------------------------------------
# Pure functions (no I/O — tested in WindowsPatchCheck.Tests.ps1)
# ---------------------------------------------------------------------------

function Resolve-BuildInfo {
    Param(
        [Parameter(Mandatory)][string]$BuildNumber,
        [Parameter(Mandatory)]$Database
    )
    return $Database.builds | Where-Object { $_.build -eq $BuildNumber } | Select-Object -First 1
}

function Get-LatestForFamily {
    Param(
        [Parameter(Mandatory)][int]$Major,
        [Parameter(Mandatory)]$Database
    )
    $Database.builds |
        Where-Object { $_.major -eq $Major -and $_.type -eq 'Standard' } |
        Sort-Object -Property @{Expression='year';Descending=$true},
                              @{Expression='month';Descending=$true},
                              @{Expression='build';Descending=$true} |
        Select-Object -First 1
}

function Get-MonthsBehind {
    Param(
        [Parameter(Mandatory)]$MachineEntry,
        [Parameter(Mandatory)]$LatestEntry
    )
    $machineMonths = ($MachineEntry.year * 12) + $MachineEntry.month
    $latestMonths  = ($LatestEntry.year  * 12) + $LatestEntry.month
    $diff = $machineMonths - $latestMonths
    if ($diff -gt 0) { return 0 }  # Future build (e.g. preview ahead of latest standard) — clamp to 0.
    return $diff
}

function Format-DateString {
    Param([Parameter(Mandatory)]$Entry)
    $base = '{0}.{1:D2}' -f $Entry.year, $Entry.month
    switch ($Entry.type) {
        'Preview' { return "$base-Preview" }
        'OOB'     { return "$base-OOB" }
        default   { return $base }
    }
}

# ---------------------------------------------------------------------------
# I/O functions
# ---------------------------------------------------------------------------

function Get-MyWindowsVersion {
    # Get-ItemPropertyValue is PS 5+; use Get-ItemProperty for PS 3/4 compat.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $props = Get-ItemProperty -Path $key
    $currentBuild = $props.CurrentBuild
    # UBR (Update Build Revision) is missing on Server 2012 R2 / Win 8.1 and
    # earlier. Default to 0 so the build number still has a valid format.
    $ubr = if ($null -ne $props.UBR) { $props.UBR } else { 0 }
    return [PSCustomObject]@{
        BuildNumber = "$currentBuild.$ubr"
        Major       = [int]$currentBuild
    }
}

function Test-IsInsider {
    try {
        $brl = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
                                -Name 'BranchReadinessLevel' -ErrorAction SilentlyContinue
        if ($null -ne $brl -and $brl.BranchReadinessLevel -gt 0) { return $true }
    } catch { }
    try {
        $ring = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability' `
                                 -Name 'Ring' -ErrorAction SilentlyContinue
        if ($null -ne $ring -and $ring.Ring -eq 'External') { return $true }
    } catch { }
    return $false
}

function Get-BuildDatabase {
    Param(
        [string]$Url,
        [string]$CacheDir,
        [int]$CacheMaxAgeHours,
        [int]$FallbackMaxAgeDays,
        [string]$FallbackJson
    )

    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }
    $cachePath = Join-Path $CacheDir 'windows-builds.json'

    # Use fresh cache if within TTL.
    if (Test-Path $cachePath) {
        $age = (Get-Date) - (Get-Item $cachePath).LastWriteTime
        if ($age.TotalHours -lt $CacheMaxAgeHours) {
            Write-Verbose "Using cached database (age: $([int]$age.TotalMinutes)m)"
            return (Get-Content $cachePath -Raw | ConvertFrom-Json)
        }
    }

    # Try network fetch.
    try {
        Write-Verbose "Fetching $Url"
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $content = $response.Content
        [System.IO.File]::WriteAllText($cachePath, $content)
        return ($content | ConvertFrom-Json)
    } catch {
        Write-Warning "Network fetch failed: $($_.Exception.Message)"
    }

    # Fall back to stale cache.
    if (Test-Path $cachePath) {
        Write-Warning "Using stale cache"
        return (Get-Content $cachePath -Raw | ConvertFrom-Json)
    }

    # Fall back to embedded JSON.
    $fallback = $FallbackJson | ConvertFrom-Json
    $fallbackAge = (Get-Date) - [datetime]::Parse($fallback.updatedAt)
    if ($fallbackAge.TotalDays -gt $FallbackMaxAgeDays) {
        throw "No network, no cache, and embedded fallback is $([int]$fallbackAge.TotalDays) days old (>$FallbackMaxAgeDays)."
    }
    Write-Warning "Using embedded fallback database"
    return $fallback
}

function Set-NinjaFields {
    Param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$BuildNumber,
        [Parameter(Mandatory)][int]$CollectedAt,
        [string]$DateString = '',
        $MonthsBehind = $null
    )

    # Verbose dump so the Ninja activity log shows exactly what we're about
    # to write — useful for diagnosing field-validation rejections.
    $behindDisplay = if ($null -ne $MonthsBehind) {
        $t = $MonthsBehind.GetType().FullName
        "'$MonthsBehind' (type=$t)"
    } else {
        '<not written>'
    }
    Write-Host "===== Ninja field write ====="
    Write-Host "  windowscumulativeupdatestatus        = '$Status'"
    Write-Host "  windowscumulativeupdateversion       = '$BuildNumber'"
    Write-Host "  windowscumulativeupdatedatacollected = $CollectedAt"
    Write-Host "  windowscumulativeupdatedate          = '$DateString'"
    Write-Host "  windowscumulativeupdatedifference    = $behindDisplay"
    Write-Host "============================="

    Ninja-Property-Set windowscumulativeupdatestatus        $Status
    Ninja-Property-Set windowscumulativeupdateversion       $BuildNumber
    Ninja-Property-Set windowscumulativeupdatedatacollected $CollectedAt
    Ninja-Property-Set windowscumulativeupdatedate          $DateString
    if ($null -ne $MonthsBehind) {
        # Force to Int32 — defensive in case upstream returned an array,
        # Int64, or string. Ninja's Integer field is Int32-bounded.
        $intValue = [int]($MonthsBehind | Select-Object -First 1)
        Ninja-Property-Set windowscumulativeupdatedifference $intValue
    }
    # When $MonthsBehind is $null (non-OK status), leave the integer field
    # untouched — Ninja rejects empty-string writes to Integer-typed fields.
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Invoke-Main {
    Param(
        [string]$DataUrl,
        [string]$CacheDir,
        [int]$CacheMaxAgeHours,
        [int]$FallbackMaxAgeDays,
        [string]$FallbackJson
    )

    # ToUnixTimeSeconds() requires .NET 4.6 (PS 5+); compute manually for PS 3/4.
    $collectedAt = [int]((Get-Date).ToUniversalTime() - (New-Object DateTime 1970,1,1)).TotalSeconds
    $version = $null

    try {
        Write-Host "Get-WindowsCumulativeUpdate.ps1 v$ScriptVersion"
        $version = Get-MyWindowsVersion
        Write-Host "Detected build: $($version.BuildNumber)"

        if (Test-IsInsider) {
            # Insider devices are continuously updated outside Patch Tuesday
            # cadence, so "months behind" isn't meaningful. Report 0 so they
            # pass compliance dashboards that filter on the difference field.
            Set-NinjaFields -Status 'Insider' `
                            -BuildNumber $version.BuildNumber `
                            -CollectedAt $collectedAt `
                            -MonthsBehind 0
            return 0
        }

        $db = Get-BuildDatabase -Url $DataUrl -CacheDir $CacheDir `
                                -CacheMaxAgeHours $CacheMaxAgeHours `
                                -FallbackMaxAgeDays $FallbackMaxAgeDays `
                                -FallbackJson $FallbackJson

        $machine = Resolve-BuildInfo -BuildNumber $version.BuildNumber -Database $db
        if ($null -eq $machine) {
            Write-Warning "Build $($version.BuildNumber) not in database"
            Set-NinjaFields -Status 'UnknownBuild' -BuildNumber $version.BuildNumber -CollectedAt $collectedAt
            return 0
        }

        $latest = Get-LatestForFamily -Major $version.Major -Database $db
        if ($null -eq $latest) {
            Write-Warning "No Standard update found for major $($version.Major)"
            Set-NinjaFields -Status 'UnknownBuild' -BuildNumber $version.BuildNumber -CollectedAt $collectedAt
            return 0
        }

        $behind = Get-MonthsBehind -MachineEntry $machine -LatestEntry $latest
        $dateStr = Format-DateString -Entry $machine

        Set-NinjaFields -Status 'OK' `
                        -BuildNumber $version.BuildNumber `
                        -CollectedAt $collectedAt `
                        -DateString $dateStr `
                        -MonthsBehind $behind
        return 0
    }
    catch [System.Net.WebException] {
        Write-Error "Network error: $_"
        $build = if ($version) { $version.BuildNumber } else { 'unknown' }
        Set-NinjaFields -Status 'NetworkError' -BuildNumber $build -CollectedAt $collectedAt
        return 1
    }
    catch {
        Write-Error "Script error: $_"
        Write-Error $_.ScriptStackTrace
        $build = if ($version) { $version.BuildNumber } else { 'unknown' }
        try {
            Set-NinjaFields -Status 'ScriptError' -BuildNumber $build -CollectedAt $collectedAt
        } catch {
            Write-Error "Also failed to write error status to Ninja: $_"
        }
        return 1
    }
}

# Only run Main when executed as a script, not when dot-sourced by tests.
# Tests set $env:WBT_SKIP_MAIN=1 before dot-sourcing.
if (-not $env:WBT_SKIP_MAIN) {
    if ([string]::IsNullOrEmpty($CacheDir)) {
        $baseDir = if ($env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }
        $CacheDir = Join-Path $baseDir 'WindowsPatchCheck'
    }
    $rc = Invoke-Main -DataUrl $DataUrl -CacheDir $CacheDir `
                      -CacheMaxAgeHours $CacheMaxAgeHours `
                      -FallbackMaxAgeDays $FallbackMaxAgeDays `
                      -FallbackJson $FallbackJson
    exit $rc
}
