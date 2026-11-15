import Foundation

/// Petits outils numériques, équivalents à ceux de numpy utilisés par juge_ligne.py.
/// Les polynômes sont rangés du plus haut degré au plus bas, comme dans numpy.
public enum Maths {
    /// Médiane (moyenne des deux valeurs centrales pour un nombre pair), comme np.median.
    public static func median(_ v: [Double]) -> Double {
        precondition(!v.isEmpty)
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Ajustement aux moindres carrés d'un polynôme de degré `deg` (1 ou 2), comme np.polyfit.
    public static func polyfit(_ x: [Double], _ y: [Double], _ deg: Int) -> [Double] {
        precondition(x.count == y.count && x.count > deg)
        // Centrage et mise à l'échelle de x pour un bon conditionnement, puis retour aux coefficients bruts.
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        var sx = x.map { abs($0 - mx) }.max() ?? 1
        if sx == 0 { sx = 1 }
        let u = x.map { ($0 - mx) / sx }
        let m = deg + 1
        // Matrice normale A^T A et second membre A^T y (colonnes u^deg ... u^0).
        var ata = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        var aty = [Double](repeating: 0, count: m)
        for i in 0..<u.count {
            var row = [Double](repeating: 1, count: m)
            for j in stride(from: m - 2, through: 0, by: -1) { row[j] = row[j + 1] * u[i] }
            for a in 0..<m {
                aty[a] += row[a] * y[i]
                for b in 0..<m { ata[a][b] += row[a] * row[b] }
            }
        }
        let c = solve(ata, aty)  // coefficients en u, du plus haut degré au plus bas
        // Développe p(u) avec u = (x - mx)/sx en coefficients en x.
        var out = [Double](repeating: 0, count: m)  // out[j] = coefficient de x^(deg-j)
        for (j, cj) in c.enumerated() {
            let p = deg - j  // cj * ((x - mx)/sx)^p
            let scale = cj / pow(sx, Double(p))
            for k in 0...p {  // binôme : C(p,k) x^k (-mx)^(p-k)
                let coef = scale * Double(binom(p, k)) * pow(-mx, Double(p - k))
                out[deg - k] += coef
            }
        }
        return out
    }

    static func binom(_ n: Int, _ k: Int) -> Int {
        if k == 0 || k == n { return 1 }
        var r = 1
        for i in 0..<k { r = r * (n - i) / (i + 1) }
        return r
    }

    /// Résolution d'un petit système linéaire par élimination de Gauss avec pivot partiel.
    static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double] {
        var a = a0, b = b0
        let n = b.count
        for col in 0..<n {
            var piv = col
            for r in col..<n where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            a.swapAt(col, piv); b.swapAt(col, piv)
            let d = a[col][col]
            if d == 0 { continue }
            for r in 0..<n where r != col {
                let f = a[r][col] / d
                if f == 0 { continue }
                for c in col..<n { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        return (0..<n).map { a[$0][$0] == 0 ? 0 : b[$0] / a[$0][$0] }
    }

    /// Valeur d'un polynôme, comme np.polyval.
    @inline(__always)
    public static func polyval(_ p: [Double], _ x: Double) -> Double {
        var r = 0.0
        for c in p { r = r * x + c }
        return r
    }

    /// Dérivée, comme np.polyder.
    public static func polyder(_ p: [Double]) -> [Double] {
        let n = p.count - 1
        if n <= 0 { return [0] }
        return (0..<n).map { p[$0] * Double(n - $0) }
    }

    /// Différence de deux polynômes de degrés éventuellement différents, comme np.polysub.
    public static func polysub(_ a: [Double], _ b: [Double]) -> [Double] {
        let n = max(a.count, b.count)
        let pa = [Double](repeating: 0, count: n - a.count) + a
        let pb = [Double](repeating: 0, count: n - b.count) + b
        return zip(pa, pb).map { $0 - $1 }
    }

    /// Racines réelles d'un polynôme de degré ≤ 2 (les zéros de tête sont ignorés, comme np.roots).
    public static func realRoots(_ p0: [Double]) -> [Double] {
        var p = p0
        while let f = p.first, f == 0 { p.removeFirst() }
        switch p.count {
        case 0, 1: return []
        case 2: return [-p[1] / p[0]]
        case 3:
            let (a, b, c) = (p[0], p[1], p[2])
            let disc = b * b - 4 * a * c
            if disc < 0 { return [] }
            let s = disc.squareRoot()
            // forme numériquement stable
            let q = -0.5 * (b + (b >= 0 ? s : -s))
            var r: [Double] = []
            if q != 0 { r.append(c / q) }
            r.append(q / a)
            if q == 0 { r.append(0) }
            return r
        default:
            preconditionFailure("degré > 2 non géré")
        }
    }
}
