# File containing functions to update particle positions based on different forces

# computes seepage velocities at particle positions
#include("SeepageForce.jl")   # itself calls CellLists.jl, isInside.jl, BarycentricInterpolation.jl
#include("CohesionForce.jl")  # itself calls CellLists.jl
#include("AdhesionForce.jl")  # itself calls CellLists.jl, SinkholeTypes.jl, CohesionForce.jl, isInside.jl

# Uses:
#   1. Graviational Force
#   2. Seepage Force (fluid velocity)
#   3. particle-particle Cohesion Force (Lennard Jones Potential)
#   4. particle-particle Adhesion Force (Lennard Jones Potential)
function updateParticle_all!(mesh,pList::Vector{Point2D{T}},rList::Vector{T},wList::Vector{W},
                                u::Vector{T},v::Vector{T},paramArr,Δt::T,
                                femCLmap::Array{Array{Int64,N} where N,1},
                                clL,clTotalBounds,particleCL,
                                polygon::Vector{Point2D{T}},extremePoint::Point2D{T},
                                w::Vector{T},uEl::Vector{T},vEl::Vector{T},
                                a::Vector{T},b::Vector{T},c::Vector{T},d::Vector{T},
                                pointOnWall::Point2D{T},xquad::Vector{T},yquad::Vector{T},
                                uSeepage::Vector{T},vSeepage::Vector{T},
                                cfX::Vector{T},cfY::Vector{T},afX::Vector{T},afY::Vector{T}) where {T<:Real, W<:AbstractWall}

    pUarr,pVarr = computeParticleVelocity_all(mesh,pList,rList,wList,u,v,paramArr,femCLmap,clL,clTotalBounds,particleCL,
                                                polygon,extremePoint,w,uEl,vEl,
                                                a,b,c,d,pointOnWall,xquad,yquad,uSeepage,vSeepage,cfX,cfY,afX,afY)

    # =========================
    # Update particle position -- this is where verlet integration might come into play
    # =========================
    for ti=1:length(rList)
        pList[ti].x += pUarr[ti]*Δt
        pList[ti].y += pVarr[ti]*Δt
    end

    nothing
end

function updateParticle_all_nofluid!(pList::Vector{Point2D{T}},rList::Vector{T},wList::Vector{W},
                                    paramArr,Δt::T,clL,clTotalBounds,particleCL,
                                    polygon::Vector{Point2D{T}},extremePoint::Point2D{T},
                                    pointOnWall::Point2D{T},xquad::Vector{T},yquad::Vector{T},
                                    cfX::Vector{T},cfY::Vector{T},afX::Vector{T},afY::Vector{T}) where {T<:Real, W<:AbstractWall}

    pUarr,pVarr = computeParticleVelocity_all_nofluid(pList,rList,wList,paramArr,clL,clTotalBounds,particleCL,
                                    polygon,extremePoint,pointOnWall,xquad,yquad,cfX,cfY,afX,afY)

    # =========================
    # Update particle position -- this is where verlet integration might come into play
    # =========================
    for ti=1:length(rList)
        pList[ti].x += pUarr[ti]*Δt
        pList[ti].y += pVarr[ti]*Δt
    end

    nothing
end

"""
    ComputeParticleVelocity_all!

Computes particle velocity for all particles. Goal is to have zero memory allocation and be completely type-stable

INPUT:
    mesh:      finite element mesh
    pList:     list of particle positions (in Point2D datatype)
    rList:     list of particle radii
    wList:     list of all walls for particles to interact against
    u,v:       2D velocity components
    paramArr:  array of scalar parameters -- might switch out for Parameters.jl datatypes

OUTPUT:
    // nothing (updates BLANK in-place)
    pUarr, pVarr: 2D velocity arrays for particles
"""
function computeParticleVelocity_all(mesh,pList::Vector{Point2D{T}},rList::Vector{T},wList::Vector{W},
                                        u::Vector{T},v::Vector{T},paramArr,
                                        femCLmap::Array{Array{Int64,N} where N,1},
                                        clL,clTotalBounds,particleCL,
                                        polygon::Vector{Point2D{T}},extremePoint::Point2D{T},
                                        w::Vector{T},uEl::Vector{T},vEl::Vector{T},
                                        a::Vector{T},b::Vector{T},c::Vector{T},d::Vector{T},
                                        pointOnWall::Point2D{T},xquad::Vector{T},yquad::Vector{T},
                                        uSeepage::Vector{T},vSeepage::Vector{T},
                                        cfX::Vector{T},cfY::Vector{T},afX::Vector{T},afY::Vector{T}) where {T<:Real, W<:AbstractWall}
    # G:      gravitation parameter
    # rc:     cutoff ratio
    # ϵ:      strength of LJ force
    # k:      multiple of equilibrium below which we should consider adhesion force calculations (i.e. k=2, k=5, etc)
    # Nquad:  number of quadrature nodes for particle-wall interaction (adhesion)
    G,rc,ϵ,k,Nquad = paramArr

    Nparticles = length(pList)

    # -----------------
    # USED FOR TESTING
    # -----------------
    particleVolume  = 1.0
    particleDensity = 1.0

    # GENERATE PARTICLE CELL LIST --
    # in future might want to create 2 particle cell lists,
    # one for seepage calculation and one for cohesion calculation
    # where clL changes between the two for increased efficiency
    #clL = 1.0
    #clTotalBounds = [-1.0,1.0,-1.0,1.0]         # WILL LIKELY NEED TO CHANGE!
    #particleCL = generateCellList(pList,clTotalBounds,clL)
    updateCellList!(particleCL,pList)

    # 1. compute gravitational force
    gfX = zeros(Nparticles)
    gfY = -G*ones(Nparticles)

    # 2. interpolate seepage velocity of fluid at position of particles
    # REQUIRES CELL LIST for particles and meshCLmap for FEM <-> cell list indexing of elements
    # compute cohesion force on all particles using cell list
    BarycentricVelocityInterp_CL!(uSeepage,vSeepage,mesh,u,v,pList,polygon,particleCL,
                                    femCLmap,extremePoint,w,uEl,vEl,a,b,c,d)
    #for ti=1:Nparticles
    #    uSeepage[ti],vSeepage[ti] = BarycentricVelocityInterp(mesh,u,v,pList[ti],polygon,
    #                                    extremePoint,w,uEl,vEl,a,b,c,d)
    #end

    # 3. compute cohesion forces
    #computeCohesion!(cfX,cfY,pList,rList,rc,ϵ)
    computeCohesion_CL!(cfX,cfY,pList,rList,rc,ϵ,particleCL)

    # 4. compute adhesion forces
    AdhesionForce!(afX,afY,pList,rList,wList,k,ϵ,pointOnWall,xquad,yquad)

    # 5. use stokes force balance to compute particle velocities
    #κ = permeability
    κ = 1.0
    #n = porosity
    n = 1.0
    #gammas = specific weight
    gammas = 1.0
    pUarr = gfX + cfX + afX + uSeepage
    pVarr = gfY + cfY + afY + vSeepage

    return pUarr,pVarr
end

function computeParticleVelocity_all_nofluid(pList::Vector{Point2D{T}},rList::Vector{T},wList::Vector{W},
                                            paramArr,clL,clTotalBounds,particleCL,
                                            polygon::Vector{Point2D{T}},extremePoint::Point2D{T},
                                            pointOnWall::Point2D{T},xquad::Vector{T},yquad::Vector{T},
                                            cfX::Vector{T},cfY::Vector{T},afX::Vector{T},afY::Vector{T}) where {T<:Real, W<:AbstractWall}
    # G:      gravitation parameter
    # rc:     cutoff ratio
    # ϵ:      strength of LJ force
    # k:      multiple of equilibrium below which we should consider adhesion force calculations (i.e. k=2, k=5, etc)
    # Nquad:  number of quadrature nodes for particle-wall interaction (adhesion)
    G,rc,ϵ,k,Nquad = paramArr

    Nparticles = length(pList)

    # -----------------
    # USED FOR TESTING
    # -----------------
    particleVolume  = 1.0
    particleDensity = 1.0

    # GENERATE PARTICLE CELL LIST --
    # in future might want to create 2 particle cell lists,
    # one for seepage calculation and one for cohesion calculation
    # where clL changes between the two for increased efficiency
    #clL = 1.0
    #clTotalBounds = [-1.0,1.0,-1.0,1.0]         # WILL LIKELY NEED TO CHANGE!
    #particleCL = generateCellList(pList,clTotalBounds,clL)
    updateCellList!(particleCL,pList)

    # 1. compute gravitational force
    gfX = zeros(Nparticles)
    gfY = -G*ones(Nparticles)

    # 2. interpolate seepage velocity of fluid at position of particles
    # not done when there is no fluid

    # 3. compute cohesion forces
    #computeCohesion!(cfX,cfY,pList,rList,rc,ϵ)
    computeCohesion_CL!(cfX,cfY,pList,rList,rc,ϵ,particleCL)

    # 4. compute adhesion forces
    AdhesionForce!(afX,afY,pList,rList,wList,k,ϵ,pointOnWall,xquad,yquad)

    # 5. use stokes force balance to compute particle velocities
    #κ = permeability
    κ = 1.0
    #n = porosity
    n = 1.0
    #gammas = specific weight
    gammas = 1.0

    pUarr = gfX + cfX + afX
    pVarr = gfY + cfY + afY

    return pUarr,pVarr
end

function computeParticleVelocity_all_TEST()
    Nparticles = 50

    # create mesh
    order = 2
    N = 64
    mesh = squareMesh([-1.0,Nparticles+1.0,-1.0,1.0],N,order)

    FEMstats(mesh)

    # create particle list
    pList = [Point2D(i-1.0,0.0) for i=1:Nparticles]

    # create radius list
    rList = ones(Nparticles)

    # create wall list (just one...)
    wList = [LineWall([Point2D(-1.0,0.0),Point2D(Nparticles,0.0)])]

    # create u,v vectors for seepage interpolation
    u = zeros(length(mesh.xy))
    v = zeros(length(mesh.xy))

    # initialize parameter array
    G=1.0; rc=1.1; ϵ=0.1; k=2; Nquad=20
    paramArr = (G,rc,ϵ,k,Nquad)

    #computeParticleVelocity_all(mesh,pList,rList,wList,u,v,paramArr)
    @btime computeParticleVelocity_all($mesh,$pList,$rList,$wList,$u,$v,$paramArr)

    nothing
end
