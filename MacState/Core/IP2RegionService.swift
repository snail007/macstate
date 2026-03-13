import Foundation

final class IP2RegionService {
    static let shared = IP2RegionService()

    private var searcher = xdb_searcher_t()
    private var contentBuffer: UnsafeMutablePointer<xdb_content_t>?
    private var ready = false

    private init() {
        guard let xdbPath = Bundle.main.path(forResource: "ip2region_v4", ofType: "xdb") else {
            return
        }

        guard let content = xdb_load_content_from_file(xdbPath) else {
            return
        }
        contentBuffer = content

        let err = xdb_new_with_buffer(xdb_version_v4(), &searcher, content)
        if err != 0 {
            xdb_free_content(content)
            contentBuffer = nil
            return
        }

        ready = true
    }

    deinit {
        if ready {
            xdb_close(&searcher)
        }
        if let buf = contentBuffer {
            xdb_free_content(buf)
        }
    }

    func search(_ ip: String) -> String? {
        guard ready else { return nil }
        if isPrivateIP(ip) { return nil }

        var region = xdb_region_buffer_t()
        xdb_region_buffer_init(&region, nil, 0)
        defer { xdb_region_buffer_free(&region) }

        let err = xdb_search_by_string(&searcher, ip, &region)
        guard err == 0, let value = region.value else { return nil }

        let raw = String(cString: value)
        return formatRegion(raw)
    }

    private func formatRegion(_ raw: String) -> String? {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map { String($0) }
        guard parts.count >= 5 else { return raw }

        let country = parts[0] == "0" ? "" : translateCountry(parts[0])
        let province = parts[1] == "0" ? "" : parts[1]
        let city = parts[2] == "0" ? "" : parts[2]
        let isp = parts[3] == "0" ? "" : translateISP(parts[3])

        var result: [String] = []
        if !country.isEmpty { result.append(country) }
        if !province.isEmpty && province != country { result.append(province) }
        if !city.isEmpty && city != province { result.append(city) }
        if !isp.isEmpty { result.append(isp) }

        return result.isEmpty ? nil : result.joined(separator: " ")
    }

    private func translateCountry(_ name: String) -> String {
        let map: [String: String] = [
            "United States": "美国",
            "United Kingdom": "英国",
            "Japan": "日本",
            "South Korea": "韩国",
            "Germany": "德国",
            "France": "法国",
            "Canada": "加拿大",
            "Australia": "澳大利亚",
            "Russia": "俄罗斯",
            "India": "印度",
            "Brazil": "巴西",
            "Singapore": "新加坡",
            "Netherlands": "荷兰",
            "Italy": "意大利",
            "Spain": "西班牙",
            "Sweden": "瑞典",
            "Switzerland": "瑞士",
            "Ireland": "爱尔兰",
            "Norway": "挪威",
            "Denmark": "丹麦",
            "Finland": "芬兰",
            "Poland": "波兰",
            "Belgium": "比利时",
            "Austria": "奥地利",
            "Portugal": "葡萄牙",
            "New Zealand": "新西兰",
            "Mexico": "墨西哥",
            "Argentina": "阿根廷",
            "Thailand": "泰国",
            "Vietnam": "越南",
            "Malaysia": "马来西亚",
            "Indonesia": "印度尼西亚",
            "Philippines": "菲律宾",
            "Turkey": "土耳其",
            "Israel": "以色列",
            "South Africa": "南非",
            "Egypt": "埃及",
            "Ukraine": "乌克兰",
            "Romania": "罗马尼亚",
            "Czech Republic": "捷克",
            "Hungary": "匈牙利",
            "Greece": "希腊",
            "Chile": "智利",
            "Colombia": "哥伦比亚",
            "Peru": "秘鲁",
            "Pakistan": "巴基斯坦",
            "Bangladesh": "孟加拉国",
            "Nigeria": "尼日利亚",
            "Kenya": "肯尼亚",
            "Iran": "伊朗",
            "Iraq": "伊拉克",
            "Saudi Arabia": "沙特阿拉伯",
            "United Arab Emirates": "阿联酋",
            "Luxembourg": "卢森堡",
            "Iceland": "冰岛",
            "Croatia": "克罗地亚",
            "Bulgaria": "保加利亚",
            "Serbia": "塞尔维亚",
            "Slovakia": "斯洛伐克",
            "Slovenia": "斯洛文尼亚",
            "Lithuania": "立陶宛",
            "Latvia": "拉脱维亚",
            "Estonia": "爱沙尼亚",
            "Cambodia": "柬埔寨",
            "Myanmar": "缅甸",
            "Nepal": "尼泊尔",
            "Sri Lanka": "斯里兰卡",
            "Mongolia": "蒙古",
            "North Korea": "朝鲜",
        ]
        return map[name] ?? name
    }

    private func translateISP(_ name: String) -> String {
        let map: [String: String] = [
            "Google": "谷歌",
            "Amazon": "亚马逊",
            "Microsoft": "微软",
            "Facebook": "脸书",
            "Cloudflare": "Cloudflare",
            "Apple": "苹果",
        ]
        return map[name] ?? name
    }

    private func isPrivateIP(_ ip: String) -> Bool {
        if ip == "0.0.0.0" || ip == "127.0.0.1" || ip == "::1" || ip == "::" || ip == "*" {
            return true
        }
        if ip.contains(":") { return false }

        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }

        if parts[0] == 10 { return true }
        if parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }

        return false
    }
}
