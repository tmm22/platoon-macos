import Foundation

// M11 practice drill scripts (owner: assist). GENERATED from the verified headless input scripts of port/verify (the
// part up to the drill starts; screenshot/dump commands removed) - see PracticeDrills.swift:
//   s0      port/verify/section0/harness/sc/honest_village_dj.port.txt (honest jungle -> bridge -> village route,
//           --start-section 0, with the jungle invincibility poke that PracticeDrills clears again)
//   s1flare port/verify/section1/scripts/fl_lit.txt (title cheat codes, tunnels, HELP -> flare night)
//   s2      port/verify/section2/honest1.txt (honest final-jungle route to the bunker)
// Format: "FRAME up|down|left|right|fire|fire0 0|1", "FRAME key HEX 0|1", "FRAME poke HEXADDR HEXVAL SIZE".

enum PracticeScripts {
    /// Drill start frames (the snapshot is taken at the first main-loop head at or after them).
    static let s0BridgeFrame = 7700
    static let s0VillageFrame = 8800
    static let s1FlareFrame = 1250
    static let s2BunkerFrame = 2195

    static func script(_ name: String) -> String {
        switch name {
        case "s0": return s0
        case "s1flare": return s1flare
        case "s2": return s2
        default: return ""
        }
    }

    /// Parsed events (frame, [command, args...]) sorted by frame.
    static func events(_ text: String) -> [(Int, [String])] {
        text.split(separator: "\n").compactMap { l -> (Int, [String])? in
            let p = l.split(separator: " ").map(String.init)
            guard p.count >= 2, let f = Int(p[0]) else { return nil }
            return (f, Array(p.dropFirst()))
        }.sorted { $0.0 < $1.0 }
    }

    static let s0 = """
706 poke 60ca0 ff 1
716 right 1
868 right 0
868 down 1
876 down 0
918 fire 0
920 right 1
1112 right 0
1112 down 1
1120 down 0
1162 fire 0
1164 right 1
1388 right 0
1388 down 1
1396 down 0
1438 fire 0
1438 right 1
1598 right 0
1598 up 1
1606 up 0
1648 fire 0
1650 left 1
1664 left 0
1664 up 1
1672 up 0
1714 fire 0
1716 right 1
1794 right 0
1794 down 1
1802 down 0
1844 fire 0
1844 right 1
1876 right 0
1876 down 1
1884 down 0
1926 fire 0
1926 right 1
2310 right 0
2310 up 1
2318 up 0
2360 fire 0
2360 right 1
2424 right 0
2424 down 1
2432 down 0
2474 fire 0
2474 right 1
2609 right 0
2609 left 1
2730 left 0
2730 up 1
2738 up 0
2780 fire 0
2780 left 1
2844 left 0
2844 down 1
2852 down 0
2894 fire 0
2894 left 1
3278 left 0
3278 up 1
3286 up 0
3328 fire 0
3328 left 1
3360 left 0
3360 up 1
3368 up 0
3410 fire 0
3410 left 1
3506 left 0
3506 down 1
3514 down 0
3556 fire 0
3556 right 1
3570 right 0
3570 down 1
3578 down 0
3620 fire 0
3620 left 1
4402 left 0
4402 up 1
4410 up 0
4452 fire 0
4452 left 1
4516 left 0
4516 up 1
4524 up 0
4566 fire 0
4566 left 1
4598 left 0
4598 up 1
4606 up 0
4648 fire 0
4648 right 1
4662 right 0
4662 up 1
4670 up 0
4712 fire 0
4712 right 1
5128 right 0
5128 down 1
5136 down 0
5178 fire 0
5178 right 1
5306 right 0
5306 up 1
5314 up 0
5356 fire 0
5358 right 1
5742 right 0
5742 down 1
5750 down 0
5792 fire 0
5792 right 1
5920 right 0
5920 up 1
5928 up 0
5970 fire 0
5970 right 1
6066 right 0
6066 down 1
6074 down 0
6116 fire 0
6116 right 1
6468 right 0
6468 down 1
6476 down 0
6518 fire 0
6520 right 1
6552 right 0
6552 down 1
6560 down 0
6602 fire 0
6602 right 1
6698 right 0
6698 down 1
6706 down 0
6748 fire 0
6748 right 1
7068 right 0
7068 up 1
7076 up 0
7118 fire 0
7118 right 1
7214 right 0
7214 down 1
7222 down 0
7264 fire 0
7264 right 1
7488 right 0
7488 up 1
7496 up 0
7538 fire 0
7538 left 1
7584 left 0
7584 up 1
7592 up 0
7634 fire 0
7634 left 1
7794 left 0
7794 up 1
7802 up 0
7844 fire 0
7846 right 1
7958 right 0
7960 poke 60ca0 0 2
8194 poke 60ca0 ff 1
8196 left 1
8405 left 0
8405 right 1
8774 right 0
8774 up 1
8782 up 0
8824 fire 0
8828 left 1
8828 fire 1
8842 fire 0
8842 left 1
"""

    static let s1flare = """
360 key 0x25 1
364 key 0x25 0
370 key 0x20 1
374 key 0x20 0
380 key 0x37 1
384 key 0x37 0
390 key 0x35 1
394 key 0x35 0
400 key 0x16 1
404 key 0x16 0
410 key 0x13 1
414 key 0x13 0
420 key 0x24 1
424 key 0x24 0
430 key 0x12 1
434 key 0x12 0
440 key 0x13 1
444 key 0x13 0
470 key 0x4a 1
474 key 0x4a 0
480 key 0x25 1
484 key 0x25 0
490 key 0x17 1
494 key 0x17 0
500 key 0x28 1
504 key 0x28 0
510 key 0x28 1
514 key 0x28 0
560 fire 1
565 fire 0
600 poke 12e4c 1 2
1100 fire 1
1105 fire 0
1200 key 0x5f 1
1210 key 0x5f 0
"""

    static let s2 = """
300 fire 1
305 fire 0
350 poke 12e4c 2 2
600 fire 1
605 fire 0
900 fire 1
905 fire 0
906 up 0
906 down 0
906 left 0
906 right 0
906 fire 0
926 up 1
929 left 1
947 left 0
954 fire 1
956 fire 0
958 fire 1
960 fire 0
962 fire 1
964 fire 0
965 fire 1
967 fire 0
969 fire 1
970 left 1
970 fire 0
976 up 0
976 left 0
986 up 1
989 left 1
1007 left 0
1014 fire 1
1016 fire 0
1018 fire 1
1020 fire 0
1022 fire 1
1024 fire 0
1026 fire 1
1028 fire 0
1030 fire 1
1031 left 1
1031 fire 0
1037 up 0
1037 left 0
1050 right 1
1051 up 1
1057 right 0
1065 left 1
1074 left 0
1079 fire 1
1080 fire 0
1082 fire 1
1084 fire 0
1085 right 1
1086 fire 1
1088 fire 0
1090 fire 1
1092 fire 0
1094 fire 1
1096 fire 0
1102 up 0
1102 right 0
1114 up 1
1126 left 1
1138 left 0
1142 fire 1
1144 fire 0
1146 fire 1
1147 left 1
1148 fire 0
1150 fire 1
1151 left 0
1152 fire 0
1154 fire 1
1156 fire 0
1158 left 1
1158 fire 1
1159 fire 0
1165 up 0
1165 left 0
1177 left 1
1183 up 1
1187 left 0
1199 right 1
1205 right 0
1213 fire 1
1215 fire 0
1217 fire 1
1219 fire 0
1221 fire 1
1223 fire 0
1224 right 1
1225 up 0
1225 fire 1
1227 fire 0
1229 fire 1
1231 fire 0
1233 fire 1
1234 up 1
1235 fire 0
1243 up 0
1243 right 0
1256 up 1
1263 left 1
1269 left 0
1284 fire 1
1286 fire 0
1287 right 1
1288 fire 1
1289 right 0
1290 fire 0
1292 fire 1
1294 fire 0
1296 left 1
1296 fire 1
1297 up 0
1298 fire 0
1300 fire 1
1302 up 1
1302 fire 0
1304 fire 1
1306 fire 0
1314 up 0
1314 left 0
1326 right 1
1331 up 1
1338 right 0
1347 left 1
1348 up 0
1365 left 0
1365 right 1
1376 up 1
1384 up 0
1384 left 1
1384 right 0
1399 down 1
1401 down 0
1416 left 0
1416 right 1
1421 up 1
1428 right 0
1437 left 1
1438 up 0
1462 left 0
1462 right 1
1481 up 1
1489 up 0
1489 left 1
1489 right 0
1504 down 1
1506 down 0
1513 left 0
1513 right 1
1518 up 1
1525 right 0
1534 left 1
1535 up 0
1555 left 0
1555 right 1
1570 up 1
1578 up 0
1578 left 1
1578 right 0
1593 down 1
1595 down 0
1610 up 1
1611 left 0
1615 fire 1
1617 right 1
1617 fire 0
1618 up 0
1619 fire 1
1621 fire 0
1623 fire 1
1625 up 1
1625 fire 0
1627 fire 1
1629 fire 0
1631 fire 1
1632 up 0
1633 fire 0
1635 fire 1
1637 up 1
1637 fire 0
1639 fire 1
1641 fire 0
1643 fire 1
1645 fire 0
1651 up 0
1651 right 0
1663 up 1
1690 left 1
1691 fire 1
1693 fire 0
1695 fire 1
1696 left 0
1697 left 1
1697 fire 0
1699 fire 1
1701 fire 0
1703 fire 1
1705 fire 0
1707 fire 1
1708 fire 0
1714 up 0
1714 left 0
1726 left 1
1732 up 1
1736 left 0
1748 right 1
1754 right 0
1762 fire 1
1764 fire 0
1765 fire 1
1767 fire 0
1769 fire 1
1771 fire 0
1772 right 1
1773 fire 1
1774 up 0
1775 fire 0
1777 fire 1
1779 fire 0
1781 fire 1
1783 up 1
1783 fire 0
1785 fire 1
1786 fire 0
1792 up 0
1792 right 0
1806 up 1
1823 right 1
1828 right 0
1834 fire 1
1836 fire 0
1838 fire 1
1840 fire 0
1842 fire 1
1844 fire 0
1846 fire 1
1847 right 1
1848 fire 0
1850 fire 1
1851 fire 0
1857 up 0
1857 right 0
1869 up 1
1897 left 1
1897 fire 1
1899 fire 0
1901 fire 1
1903 fire 0
1905 fire 1
1907 fire 0
1909 fire 1
1911 fire 0
1913 fire 1
1914 fire 0
1920 up 0
1920 left 0
1932 up 1
1950 right 1
1953 right 0
1960 fire 1
1962 fire 0
1964 fire 1
1966 fire 0
1968 fire 1
1970 fire 0
1971 up 0
1971 right 1
1971 fire 1
1972 up 1
1973 fire 0
1975 fire 1
1977 fire 0
1983 up 0
1983 right 0
1994 up 1
2021 left 1
2022 fire 1
2024 fire 0
2026 fire 1
2027 left 0
2028 left 1
2028 fire 0
2030 fire 1
2032 fire 0
2034 fire 1
2036 fire 0
2038 fire 1
2039 fire 0
2045 up 0
2045 left 0
2057 up 1
2074 right 1
2079 right 0
2085 fire 1
2087 fire 0
2089 fire 1
2091 fire 0
2093 fire 1
2095 fire 0
2097 fire 1
2098 right 1
2099 fire 0
2101 fire 1
2102 fire 0
2108 up 0
2108 right 0
2121 left 1
2127 up 1
2131 left 0
2143 right 1
2149 right 0
2157 fire 1
2159 left 1
2159 fire 0
2161 fire 1
2163 fire 0
2165 fire 1
2167 fire 0
2169 fire 1
2171 fire 0
2178 up 0
2178 left 0
2190 up 1
2200 up 0
2200 fire 1
2202 fire 0
2204 fire 1
2206 fire 0
2208 fire 1
2210 left 1
2210 fire 0
2213 left 0
2221 fire 1
2223 fire 0
2225 fire 1
2227 fire 0
2241 up 1
2241 left 1
2245 up 0
2245 left 0
2249 up 1
2250 up 0
2254 up 1
2254 right 1
2261 right 0
2286 up 0
2500 fire 1
2505 fire 0
2800 right 1
2802 right 0
2815 fire 1
2817 fire 0
2830 right 1
2832 right 0
2845 fire 1
2847 fire 0
2860 right 1
2862 right 0
2875 fire 1
2877 fire 0
2890 right 1
2892 right 0
2905 fire 1
2907 fire 0
2920 right 1
2922 right 0
2935 fire 1
2937 fire 0
2950 right 1
2952 right 0
2965 fire 1
2967 fire 0
2980 right 1
2982 right 0
2995 fire 1
2997 fire 0
3010 right 1
3012 right 0
3025 fire 1
3027 fire 0
3040 right 1
3042 right 0
3055 fire 1
3057 fire 0
3070 right 1
3072 right 0
3085 fire 1
3087 fire 0
3100 right 1
3102 right 0
3115 fire 1
3117 fire 0
3150 fire 1
3152 fire 0
3180 fire 1
3182 fire 0
3210 fire 1
3212 fire 0
3240 fire 1
3242 fire 0
3270 fire 1
3272 fire 0
3300 fire 1
3302 fire 0
3330 fire 1
3332 fire 0
3360 fire 1
3362 fire 0
3390 fire 1
3392 fire 0
3420 fire 1
3422 fire 0
3450 fire 1
3452 fire 0
3480 fire 1
3482 fire 0
3510 fire 1
3512 fire 0
3540 fire 1
3542 fire 0
3570 fire 1
3572 fire 0
3600 fire 1
3602 fire 0
3630 fire 1
3632 fire 0
3660 fire 1
3662 fire 0
3690 fire 1
3692 fire 0
"""
}
