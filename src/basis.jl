"""
$(TYPEDEF)

# Fields

Accessing fields directly is part of the API. The additional property `cap` is supported.

$(FIELDS)
"""
struct HomogeneousBasis{N,U}
    "The univariate family, eg `Chebyshev()`."
    univariate::U
    "Indexes by dimensions."
    I::NTuple{N,Int}
    "The level (`≥ 0`) of the Smolyak approximation. `cap = level + N`."
    level::Int
end

function Base.propertynames(basis::HomogeneousBasis, private = false)
    (fieldnames(HomogeneousBasis)..., :cap)
end

function Base.getproperty(basis::HomogeneousBasis{N}, name::Symbol) where {N}
    if name ≡ :cap
        N + basis.level
    else
        getfield(basis, name)
    end
end

function degrees_of_freedom(basis::HomogeneousBasis)
    @unpack univariate, I, cap = basis
    C = mapfoldl((C1, C2) -> count_combinations(cap, C1, C2), I) do i
        indexes = 1:min(i, cap)
        Counts(indexes, set_length.(univariate, indexes))
    end
    sum(C)
end

"""
$(SIGNATURES)

Calculate the matrix `A[R[i[end]], R[j[end]] ⊗ … ⊗ A[R[i[2]], R[j[2]] ⊗ A[R[i[1]], R[j[1]]`,
where

- `A` is the basis matrix for all points and basis functions,

- `R` contains the ranges for each index,

- `i` and `j` are iterables of indexes in `R`.

Internal helper function used in building basis matrices.
"""
function _basis_block(A, R, i, j)
    mapreduce(((i, j), ) -> A[R[i], R[j]], (A1, A2) -> kron(A2, A1), zip(i, j))
end

"""
$(SIGNATURES)

Calculate all combinations of `x[R[i[1]]], x[R[i[2]]], …`, with the first index changing the
fastest (column major).

Internal helper function used in building coordinates.
"""
function _coordinate_block(x, R, i)
    mapfoldl(i -> x[R[i]],
             (y, x) -> vec(((x, y) -> (x, y...)).(x, permutedims(y))),
             reverse(i), init = [()])
end

"""
$(SIGNATURES)

Return `A, v` where `A` is a ``d × d`` matrix and `v` is a `d`-element vector, where

- `d = degrees_of_freedom(basis)`,

- `v` is a vector of *coordinates*,

- `A \\ f.(x)` would calculate the *coefficients* of approximating `f`.
"""
function basis_matrix_and_coordinates(basis::HomogeneousBasis)
    @unpack univariate, I, cap = basis
    iter = CappedCartesianIndices(cap, I)
    K = maximum(largest_indices(iter))

    # univariate building blocks
    R = set_range.(univariate, 1:K)
    x0 = all_gridpoints(univariate, K)
    A0 = evaluate(last(last(R)), univariate, x0)

    # combinations
    # FIXME these could be made much more efficient by pre-allocating, and making
    # `_basis_block` and `_coordinate_block` mutate a pre-allocated matrix
    A = mapreduce(j -> mapreduce(i -> _basis_block(A0, R, i, j), vcat, iter), hcat, iter)
    x = mapreduce(i -> _coordinate_block(x0, R, i), vcat, iter)
    A, SVector.(x)
end

"""
$(SIGNATURES)

Helper function for iterating when interpolating `basis` at `x`.

Return a `NamedTuple` of

- `iter`: an iterator for the set indices,
- `R`: a vector of set ranges
- `A0s`: basis matrices for each coordinate, to be indexed by elements of `R`
"""
function _interpolation_helper(basis::HomogeneousBasis{N}, x::AbstractVector) where {N}
    @argcheck length(x) == N
    @unpack univariate, I, cap = basis
    iter = CappedCartesianIndices(cap, I)
    Ks = largest_indices(iter)
    R = set_range.(univariate, 1:maximum(Ks))
    A0s = map((K, x) -> evaluate(last(R[K]), univariate, x), Ks, x)
    (iter = iter, R = R, A0s = A0s)
end

"""
$(SIGNATURES)

Interpolate `basis` with coefficients `c` at `x`.
"""
function interpolate(basis::HomogeneousBasis, c::AbstractVector{T1},
                     x::AbstractVector{T2}) where {T1, T2}
    @unpack iter, R, A0s = _interpolation_helper(basis, x)
    S = float(promote_type(T1, T2))
    v = zero(S)
    p = 1
    for i in iter
        for I in CartesianIndices(map(i -> R[i], i))
            v += prod(map(getindex, A0s, Tuple(I))) * c[p]
            p += 1
        end
    end
    v
end

"""
$(SIGNATURES)

In-place version of [`interpolated_basis`](@ref). Overwrites the first argument,
which should have length `degrees_of_freedom(basis)`.
"""
function interpolated_basis!(a::AbstractVector, basis::HomogeneousBasis, x::AbstractVector)
    @unpack iter, R, A0s = _interpolation_helper(basis, x)
    p = 1
    for i in iter
        for I in CartesianIndices(map(i -> R[i], i))
            a[p] = prod(map(getindex, A0s, Tuple(I)))
            p += 1
        end
    end
    a
end

"""
$(SIGNATURES)

Return a vector `a` such that

```julia
dot(a, c) ≈ interpolate(basis, c, x)
```

This is useful when repeatedly interpolating at the same set of coordinates `x` (`a` is
specific to `x`).
"""
function interpolated_basis(basis::HomogeneousBasis, x::AbstractVector{T}) where{T}
    interpolated_basis!(Vector{float(T)}(undef, degrees_of_freedom(basis)), basis, x)
end
