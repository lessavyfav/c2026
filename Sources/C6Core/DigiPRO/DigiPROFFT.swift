import Foundation

extension DigiPRO {
    /// The FFT library C6 linked for the DigiPRO converter (Mac `fftInit` 0x755b called with
    /// 16384 / flags 2 at 0xa1c4, radix-2 core 0x767a, dispatcher 0x7ecb; spec §9).
    ///
    /// Every operation is written in the original's order (IEEE double, no FMA), so the output is
    /// bit-identical to `tools/digipro_ref.py`. `fixed == false` reproduces the two bit-reversal
    /// bugs (float32 temporary, no reversal at all for 32768 points); `fixed == true` is a correct
    /// FFT with the same arithmetic otherwise. See the deviation list in `DigiPRO.swift`.
    enum FFT {
        /// Largest transform the dispatcher accepts (0x125a0).
        static let maxN = 16384
        /// Size the twiddle tables were built for (0x125a4); log2 = 15.
        static let tableSize = 32768

        /// `sin`/`cos` of `(i * -2π) / 32768` for i < 16384 (0x666a4 / 0x666a8).
        static let twiddles: (sin: [Double], cos: [Double]) = {
            var s = [Double](repeating: 0, count: tableSize / 2)
            var c = [Double](repeating: 0, count: tableSize / 2)
            for i in 0..<(tableSize / 2) {
                let a = (Double(i) * -6.283185307179586) / Double(tableSize)
                s[i] = sin(a)
                c[i] = cos(a)
            }
            return (s, c)
        }()

        /// Smallest `c` with `1 << c > n` (the loop the original uses everywhere).
        static func bitLength(_ n: Int) -> Int {
            var c = 0
            while c < 32 && !((1 << c) > n) { c += 1 }
            return c
        }

        /// Mac 0x7ecb: power-of-two lengths go straight to the radix-2 core, everything else through
        /// Bluestein's chirp-z with a `2^(e+1)`-point core transform. Forward is unnormalised,
        /// inverse includes 1/n. Both arrays need at least `max(n, 4)` elements.
        static func transform(_ re: inout [Double], _ im: inout [Double], _ n: Int, inverse: Bool, fixed: Bool) {
            precondition(n >= 1 && n <= maxN && re.count >= max(n, 4) && im.count >= max(n, 4))
            let e = bitLength(n)
            if 1 << (e - 1) == n {
                radix2(&re, &im, n, inverse: inverse, fixed: fixed)
                return
            }
            let m = 1 << (e + 1)
            var wr = [Double](repeating: 0, count: n)
            var wi = [Double](repeating: 0, count: n)
            for k in 0..<n {
                let x = (Double(k * k) * Double.pi) / Double(n)
                wr[k] = cos(x)
                wi[k] = sin(x)
            }
            var ar = [Double](repeating: 0, count: m), ai = [Double](repeating: 0, count: m)
            var br = [Double](repeating: 0, count: m), bi = [Double](repeating: 0, count: m)
            if inverse { // 0x7fe0
                ar[0] = re[0] * wr[0] - im[0] * wi[0]
                ai[0] = im[0] * wr[0] + re[0] * wi[0]
                br[0] = wr[0]; bi[0] = -wi[0]
                for k in 1..<n {
                    ar[k] = re[k] * wr[k] - im[k] * wi[k]
                    ai[k] = re[k] * wi[k] + im[k] * wr[k]
                    ar[m - k] = 0; ai[m - k] = 0
                    br[k] = wr[k]; bi[k] = -wi[k]
                    br[m - k] = wr[k]; bi[m - k] = -wi[k]
                }
            } else { // 0x814f
                ar[0] = re[0] * wr[0] + im[0] * wi[0]
                ai[0] = im[0] * wr[0] - wi[0] * re[0]
                br[0] = wr[0]; bi[0] = wi[0]
                for k in 1..<n {
                    ar[k] = re[k] * wr[k] + im[k] * wi[k]
                    ai[k] = im[k] * wr[k] - wi[k] * re[k]
                    ar[m - k] = 0; ai[m - k] = 0
                    br[k] = wr[k]; bi[k] = wi[k]
                    br[m - k] = wr[k]; bi[m - k] = wi[k]
                }
            }
            for k in n...(m - n) { ar[k] = 0; ai[k] = 0; br[k] = 0; bi[k] = 0 } // 0x82c1
            radix2(&ar, &ai, m, inverse: false, fixed: fixed)
            radix2(&br, &bi, m, inverse: false, fixed: fixed)
            for k in 0..<m { // 0x8338
                let aR = ar[k], aI = ai[k], bR = br[k], bI = bi[k]
                ai[k] = aR * bI + bR * aI
                ar[k] = aR * bR - aI * bI
            }
            radix2(&ar, &ai, m, inverse: true, fixed: fixed)
            if inverse { // 0x83bd
                for k in 0..<n {
                    let r = ar[k] * wr[k] - ai[k] * wi[k]
                    let i = ai[k] * wr[k] + ar[k] * wi[k]
                    let s = 1.0 / Double(n)
                    re[k] = s * r
                    im[k] = s * i
                }
            } else { // 0x8452
                for k in 0..<n {
                    re[k] = ar[k] * wr[k] + ai[k] * wi[k]
                    im[k] = ai[k] * wr[k] - ar[k] * wi[k]
                }
            }
        }

        /// Mac 0x767a in complex mode (flags bit1 = 0, the only mode DigiPRO uses). `n` must be a
        /// power of two ≤ 32768; both arrays need at least `max(n, 4)` elements (stages 1 and 2
        /// touch indices up to 3 even for n < 4, as in the original).
        static func radix2(_ re: inout [Double], _ im: inout [Double], _ n: Int, inverse: Bool, fixed: Bool) {
            precondition(n >= 1 && n <= tableSize && n & (n - 1) == 0 && re.count >= max(n, 4) && im.count >= max(n, 4))
            let cosT = twiddles.cos, sinT = twiddles.sin
            re.withUnsafeMutableBufferPointer { rb in
                im.withUnsafeMutableBufferPointer { ib in
                    cosT.withUnsafeBufferPointer { cb in
                        sinT.withUnsafeBufferPointer { sb in
                            radix2(rb.baseAddress!, ib.baseAddress!, n, inverse: inverse, fixed: fixed,
                                   cos: cb.baseAddress!, sin: sb.baseAddress!)
                        }
                    }
                }
            }
        }

        private static func radix2(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>, _ n: Int,
                                   inverse: Bool, fixed: Bool,
                                   cos cosT: UnsafePointer<Double>, sin sinT: UnsafePointer<Double>) {
            let shift = (bitLength(tableSize) - 1) - (bitLength(n) - 1)

            // Bit reversal (0x77aa). The original keeps i, j, k and n in 16-bit shorts, so for
            // n == 32768 the loop limit `(short)n - 2` is negative and nothing is reordered; and it
            // swaps through a float temporary, rounding the element moved down to float32.
            if fixed || n < 32768 {
                var j = n >> 1
                var i = 1
                while i <= n - 2 {
                    if j > i {
                        if fixed {
                            let tr = re[j], ti = im[j]
                            re[j] = re[i]; im[j] = im[i]
                            re[i] = tr; im[i] = ti
                        } else {
                            let tr = Double(Float(re[j])), ti = Double(Float(im[j]))
                            re[j] = re[i]; im[j] = im[i]
                            re[i] = tr; im[i] = ti
                        }
                    }
                    var k = n >> 1
                    while k > 0 && j >= k { j -= k; k >>= 1 }
                    j += k
                    i += 1
                }
            }

            // Stage 1 (pairs) and stage 2 (quads).
            if inverse {
                var c = 0
                while n > c { // 0x783f
                    let s = 1.0 / Double(n)
                    var a = re[c], b = re[c + 1]
                    re[c] = (a + b) * s
                    re[c + 1] = (a - b) * s
                    a = im[c]; b = im[c + 1]
                    im[c] = (a + b) * s
                    im[c + 1] = (a - b) * s
                    c += 2
                }
                c = 0
                while n > c { // 0x78bc
                    let r0 = re[c], r2 = re[c + 2], i0 = im[c], i2 = im[c + 2]
                    re[c] = r0 + r2; im[c] = i0 + i2
                    re[c + 2] = r0 - r2; im[c + 2] = i0 - i2
                    let r1 = re[c + 1], i1 = im[c + 1], r3 = re[c + 3], i3 = im[c + 3]
                    re[c + 1] = r1 - i3; im[c + 1] = i1 + r3
                    re[c + 3] = r1 + i3; im[c + 3] = i1 - r3
                    c += 4
                }
            } else {
                var c = 0
                while n > c { // 0x7953
                    var a = re[c], b = re[c + 1]
                    re[c] = a + b; re[c + 1] = a - b
                    a = im[c]; b = im[c + 1]
                    im[c] = a + b; im[c + 1] = a - b
                    c += 2
                }
                c = 0
                while n > c { // 0x79b3
                    let r0 = re[c], r2 = re[c + 2], i0 = im[c], i2 = im[c + 2]
                    re[c] = r0 + r2; im[c] = i0 + i2
                    re[c + 2] = r0 - r2; im[c + 2] = i0 - i2
                    let r1 = re[c + 1], i1 = im[c + 1], r3 = re[c + 3], i3 = im[c + 3]
                    re[c + 1] = r1 + i3; im[c + 1] = i1 - r3
                    re[c + 3] = r1 - i3; im[c + 3] = i1 + r3
                    c += 4
                }
            }

            // Stages L = 4, 8, …, n/2 (0x7a45..0x7c16). Note `2a − (a + wb)` instead of `a − wb`.
            var l = 4
            var esi = n / 8
            while esi > 0 {
                var b = 0
                while n > b {
                    let k = b % l
                    let tw = k * (esi << shift)
                    let j = b + l
                    let wr = cosT[tw], wi = sinT[tw]
                    let xr = re[j], xi = im[j]
                    let t5: Double, t3: Double
                    if inverse {
                        t5 = (wr * xr + re[b]) + wi * xi
                        t3 = (im[b] - xr * wi) + wr * xi
                    } else {
                        t5 = (wr * xr + re[b]) - wi * xi
                        t3 = (xr * wi + im[b]) + wr * xi
                    }
                    re[j] = (re[b] + re[b]) - t5
                    im[j] = (im[b] + im[b]) - t3
                    re[b] = t5
                    im[b] = t3
                    if k == l - 1 { b = j }
                    b += 1
                }
                l <<= 1
                esi >>= 1
            }
        }
    }
}
