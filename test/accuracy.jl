using Test
using Random: Random
using AbstractFFTs: fftfreq, rfftfreq
using JET: JET
using NonuniformFFTs

function check_nufft_error(::Type{Float64}, ::Type{KaiserBesselKernel}, ::HalfSupport{M}, σ, err) where {M}
    if σ ≈ 1.25
        err_min_kb = 4e-12  # error reaches a minimum at ~2e-12 for M = 10
        # This seems to work for KaiserBesselKernel and 4 ≤ M ≤ 10
        @test err < max(10.0^(-1.16 * M) * 1.05, err_min_kb)
    elseif σ ≈ 2.0
        err_max_kb = max(6 * 10.0^(-1.9 * M), 3e-14)  # error "plateaus" at ~2e-14 for M ≥ 8
        @test err < err_max_kb
    end
    nothing
end

function check_nufft_error(::Type{Float64}, ::Type{BackwardsKaiserBesselKernel}, ::HalfSupport{M}, σ, err) where {M}
    if σ ≈ 1.25
        err_min_kb = 4e-12  # error reaches a minimum at ~2e-12 for M = 10
        @test err < max(10.0^(-1.20 * M), err_min_kb)
    elseif σ ≈ 2.0
        err_max_kb = max(6 * 10.0^(-1.9 * M), 3e-14)  # error "plateaus" at ~2e-14 for M ≥ 8
        @test err < err_max_kb
    end
    nothing
end

function check_nufft_error(::Type{Float64}, ::Type{GaussianKernel}, ::HalfSupport{M}, σ, err) where {M}
    if σ ≈ 2.0
        @test err < 10.0^(-0.95 * M) * 0.8
    end
    nothing
end

function check_nufft_error(::Type{Float64}, ::Type{BSplineKernel}, ::HalfSupport{M}, σ, err) where {M}
    if σ ≈ 2.0
        @test err < 10.0^(-0.98 * M) * 0.4
    end
    nothing
end

# TODO support T <: Complex
function test_nufft_type1_1d(
        ::Type{T};
        kernel::Type{KernelType} = KaiserBesselKernel,
        N = 256,
        Np = 2 * N,
        m = HalfSupport(8),
        σ = 1.25,
    ) where {T <: AbstractFloat, KernelType}
    ks = rfftfreq(N, N)  # wavenumbers (= [0, 1, 2, ..., N÷2])

    # Generate some non-uniform random data
    rng = Random.Xoshiro(42)
    xp = rand(rng, real(T), Np) .* 2π  # non-uniform points in [0, 2π]
    vp = randn(rng, T, Np)             # random values at points

    # Compute "exact" non-uniform transform
    ûs_exact = zeros(Complex{T}, length(ks))
    for (i, k) ∈ pairs(ks)
        ûs_exact[i] = sum(zip(xp, vp)) do (x, v)
            v * cis(-k * x)
        end
    end

    # Compute NUFFT
    ûs = Array{Complex{T}}(undef, length(ks))
    plan_nufft = PlanNUFFT(T, N, m; σ, kernel = KernelType)
    NonuniformFFTs.set_points!(plan_nufft, xp)
    NonuniformFFTs.exec_type1!(ûs, plan_nufft, vp)

    # Check results
    err = sqrt(sum(splat((a, b) -> abs2(a - b)), zip(ûs, ûs_exact)) / sum(abs2, ûs_exact))

    # Inference tests
    JET.@test_opt NonuniformFFTs.set_points!(plan_nufft, xp)
    JET.@test_opt NonuniformFFTs.exec_type1!(ûs, plan_nufft, vp)

    check_nufft_error(T, kernel, m, σ, err)

    nothing
end

function test_nufft_type2_1d(
        ::Type{T};
        kernel::Type{KernelType} = KaiserBesselKernel,
        N = 256,
        Np = 2 * N,
        m = HalfSupport(8),
        σ = 1.25,
    ) where {T <: AbstractFloat, KernelType}
    ks = rfftfreq(N, N)  # wavenumbers (= [0, 1, 2, ..., N÷2])

    # Generate some uniform random data + non-uniform points
    rng = Random.Xoshiro(42)
    ûs = randn(rng, Complex{T}, length(ks))
    xp = rand(rng, real(T), Np) .* 2π  # non-uniform points in [0, 2π]

    # Compute "exact" type-2 transform (interpolation)
    vp_exact = zeros(T, Np)
    for (i, x) ∈ pairs(xp)
        for (û, k) ∈ zip(ûs, ks)
            factor = ifelse(iszero(k), 1, 2)
            s, c = sincos(k * x)
            ur, ui = real(û), imag(û)
            vp_exact[i] += factor * (c * ur - s * ui)
        end
    end

    # Compute NUFFT
    vp = Array{T}(undef, Np)
    plan_nufft = PlanNUFFT(T, N, m; σ, kernel = KernelType)
    NonuniformFFTs.set_points!(plan_nufft, xp)
    NonuniformFFTs.exec_type2!(vp, plan_nufft, ûs)

    err = sqrt(sum(splat((a, b) -> abs2(a - b)), zip(vp, vp_exact)) / sum(abs2, vp_exact))

    check_nufft_error(T, kernel, m, σ, err)

    err
end

@testset "Type 1 NUFFTs" begin
    for M ∈ 4:10
        m = HalfSupport(M)
        σ = 1.25
        @testset "$kernel (m = $M, σ = $σ)" for kernel ∈ (KaiserBesselKernel, BackwardsKaiserBesselKernel)
            test_nufft_type1_1d(Float64; m, σ, kernel)
        end
        σ = 2.0
        @testset "$kernel (m = $M, σ = $σ)" for kernel ∈ (KaiserBesselKernel, BackwardsKaiserBesselKernel, GaussianKernel, BSplineKernel)
            test_nufft_type1_1d(Float64; m, σ, kernel)
        end
    end
end

@testset "Type 2 NUFFTs" begin
    for M ∈ 4:10
        m = HalfSupport(M)
        σ = 1.25
        @testset "$kernel (m = $M, σ = $σ)" for kernel ∈ (KaiserBesselKernel, BackwardsKaiserBesselKernel)
            test_nufft_type2_1d(Float64; m, σ, kernel)
        end
        σ = 2.0
        @testset "$kernel (m = $M, σ = $σ)" for kernel ∈ (KaiserBesselKernel, BackwardsKaiserBesselKernel, GaussianKernel, BSplineKernel)
            test_nufft_type2_1d(Float64; m, σ, kernel)
        end
    end
end
