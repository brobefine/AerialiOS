import Foundation

/// «Духовные родственники» по профилям (как `RelativeRanker` ТВ; подход Netflix и MovieLens Tag Genome): профиль — оценки
/// 0–3 по тонким чертам `RelativeCriteria` (ставит ИИ, `AI.profiles`). Подборки по сторонам исходной (`sides`): на каждую её
/// главную группу черт — свой ряд, как у Netflix «потому что вам понравилось…»; общий ряд (`rank`) — запасной.
enum RelativeRanker {
    struct Candidate {
        let id: String
        let profile: [String: Int]
        let votes: Int
        let overused: Int
    }

    struct Pick {
        let id: String
        let score: Double
        /// Группа черт исходной, за которую работа в подборке (nil — общий ряд).
        var aspect: String?
    }

    static let popularity = 0.03
    static let overusedPenalty = 0.04
    static let diversity = 0.25
    static let extra = 0.15
    static let maxAspects = 5
    static let aspectFloor = 0.2
    static let minRow = 4

    /// Профиль с оценками групп: к тонким чертам добавляется группа — максимум по её чертам.
    static func expand(_ profile: [String: Int]) -> [String: Int] {
        var out = profile
        for (key, score) in profile {
            guard let group = RelativeCriteria.criterion(key)?.group else { continue }
            if score > (out[group] ?? 0) { out[group] = score }
        }
        return out
    }

    /// Родство с исходной: покрытие её черт (сильные весят больше) минус лёгкий штраф за сильные черты кандидата, которых
    /// у исходной нет.
    static func similarity(_ seed: [String: Int], _ other: [String: Int]) -> Double {
        let s = expand(seed), o = expand(other)
        var covered = 0.0, total = 0.0
        for (key, v) in s where v > 0 {
            let w = Double(v * v)
            total += w
            covered += w * Double(min(v, o[key] ?? 0)) / Double(v)
        }
        let mass = Double(o.values.reduce(0, +))
        guard total > 0, mass > 0 else { return 0 }
        let extraMass = o.reduce(0.0) { $0 + Double(max(0, $1.value - (s[$1.key] ?? 0))) }
        return covered / total - extra * extraMass / mass
    }

    /// Насколько похожи два кандидата между собой (косинус) — для разнообразия.
    static func closeness(_ a: [String: Int], _ b: [String: Int]) -> Double {
        let x = expand(a), y = expand(b)
        var dot = 0.0, na = 0.0, nb = 0.0
        for key in Set(x.keys).union(y.keys) {
            let p = Double(x[key] ?? 0), q = Double(y[key] ?? 0)
            dot += p * q; na += p * p; nb += q * q
        }
        return na == 0 || nb == 0 ? 0 : dot / (na * nb).squareRoot()
    }

    static func shares(_ seed: [String: Int], _ other: [String: Int]) -> Bool {
        let s = expand(seed), o = expand(other)
        return s.contains { key, v in min(v, o[key] ?? 0) >= 2 }
    }

    /// Главные стороны исходной: её группы с оценкой не ниже 2, сначала сильные, без слишком общих черт.
    static func aspects(_ seed: [String: Int]) -> [String] {
        var groups: [String: Int] = [:]
        for (key, v) in seed where v >= 2 && !RelativeCriteria.generic.contains(key) {
            guard let g = RelativeCriteria.criterion(key)?.group else { continue }
            groups[g] = max(groups[g] ?? 0, v)
        }
        return groups.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(maxAspects).map(\.key)
    }

    /// Насколько работа повторяет одну сторону исходной: тонкие черты группы (половина) и группу в целом (половина).
    static func aspectScore(_ seed: [String: Int], _ other: [String: Int], _ group: String) -> Double {
        let fine = seed.filter { RelativeCriteria.criterion($0.key)?.group == group }
        guard !fine.isEmpty else { return 0 }
        let total = Double(fine.values.reduce(0, +))
        let covered = fine.reduce(0.0) { $0 + Double(min($1.value, other[$1.key] ?? 0)) }
        let seedG = expand(seed)[group] ?? 0, otherG = expand(other)[group] ?? 0
        return 0.5 * covered / total + 0.5 * Double(min(seedG, otherG)) / Double(max(1, seedG))
    }

    private static func penalty(_ c: Candidate) -> Double {
        (c.votes > 1000 ? log10(Double(c.votes) / 1000) * popularity : 0) + Double(c.overused) * overusedPenalty
    }

    private static func usable(_ seed: [String: Int], _ candidates: [Candidate]) -> [Candidate] {
        candidates.filter { !$0.profile.isEmpty && shares(seed, $0.profile) }
    }

    /// Общий ряд: по общему сходству с разнообразием (MMR) — запасной, если подборок по сторонам не набралось.
    static func rank(_ seed: [String: Int], _ candidates: [Candidate], count: Int = 20) -> [Pick] {
        var left = usable(seed, candidates).map { ($0, similarity(seed, $0.profile) - penalty($0)) }
        var picked: [Candidate] = [], chosen: [Pick] = []
        while chosen.count < count, !left.isEmpty {
            let index = left.indices.max { a, b in
                func value(_ i: Int) -> Double {
                    let near = picked.map { closeness($0.profile, left[i].0.profile) }.max() ?? 0
                    return (1 - diversity) * left[i].1 - diversity * near
                }
                return value(a) < value(b)
            }!
            let best = left.remove(at: index)
            picked.append(best.0)
            chosen.append(Pick(id: best.0.id, score: best.1))
        }
        return chosen
    }

    /// Подборки по сторонам исходной: на каждую — до `perRow` работ, лучших именно по ней (70 % — сторона, 30 % — общее
    /// сходство). Работа — в одной подборке, где совпадение сильнее; подборка короче `minRow` не показывается, её работы
    /// переходят в следующую подходящую сторону.
    static func sides(_ seed: [String: Int], _ candidates: [Candidate], perRow: Int = 10) -> [(String, [Pick])] {
        let pool = usable(seed, candidates)
        var overall: [String: Double] = [:]
        for c in pool { overall[c.id] = similarity(seed, c.profile) }
        let groups = aspects(seed)
        func score(_ c: Candidate, _ g: String) -> Double { 0.7 * aspectScore(seed, c.profile, g) + 0.3 * (overall[c.id] ?? 0) - penalty(c) }
        var rows: [String: [Candidate]] = [:]
        for c in pool where (overall[c.id] ?? 0) >= aspectFloor {
            if let g = groups.filter({ aspectScore(seed, c.profile, $0) >= 0.5 }).max(by: { score(c, $0) < score(c, $1) }) {
                rows[g, default: []].append(c)
            }
        }
        let kept = Set(rows.filter { $0.value.count >= minRow }.keys)
        for (g, list) in rows where !kept.contains(g) {
            for c in list {
                if let next = kept.filter({ aspectScore(seed, c.profile, $0) >= 0.5 }).max(by: { score(c, $0) < score(c, $1) }) {
                    rows[next, default: []].append(c)
                }
            }
        }
        return groups.filter { kept.contains($0) }.map { g in
            (g, (rows[g] ?? []).sorted { score($0, g) > score($1, g) }.prefix(perRow).map { Pick(id: $0.id, score: overall[$0.id] ?? 0, aspect: g) })
        }
    }

    /// Профиль из ответа ИИ: только тонкие черты словаря с оценкой 1–3.
    static func profile(_ raw: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, value) in raw {
            let k = key.trimmingCharacters(in: .whitespaces).lowercased()
            if RelativeCriteria.criterion(k) != nil, (1...3).contains(value) { out[k] = value }
        }
        return out
    }
}
