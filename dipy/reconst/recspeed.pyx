# Emacs should think this is a -*- python -*- file
""" Optimized routines for creating voxel diffusion models
"""

# cython: profile=True
# cython: embedsignature=True

cimport cython

import numpy as np
cimport numpy as cnp



cdef extern from "math.h" nogil:
    double floor(double x)
    float fabs(float x)
    double log2(double x)
    double cos(double x)
    double sin(double x)
    float acos(float x )
    bint isnan(double x)
    double sqrt(double x)


DEF PI=3.1415926535897931


# initialize numpy runtime
cnp.import_array()

#numpy pointers
cdef inline float* asfp(cnp.ndarray pt):
    return <float *>pt.data

cdef inline double* asdp(cnp.ndarray pt):
    return <double *>pt.data

@cython.wraparound(False)
def trilinear_interp(cnp.ndarray[cnp.float_t, ndim=4] data, 
                     cnp.ndarray[cnp.float_t, ndim=1] index,
                     cnp.ndarray[cnp.float_t, ndim=1] voxel_size):
    """Interpolates data at index

    Interpolates data from a 4d volume, first 3 dimenssions are x, y, z the
    last dimenssion holds data.
    """
    cdef:
        float x = index[0] / voxel_size[0] - .5
        float y = index[1] / voxel_size[1] - .5
        float z = index[2] / voxel_size[2] - .5
        float weight
        int x_ind = <int> floor(x)
        int y_ind = <int> floor(y)
        int z_ind = <int> floor(z)
        int ii, jj, kk, LL
        int last_d = data.shape[3]
        cnp.ndarray[cnp.float_t, ndim=1] result=np.zeros(last_d)
    x = x % 1
    y = y % 1
    z = z % 1

    for ii from 0 <= ii <= 1:
        for jj from 0 <= jj <= 1:
            for kk from 0 <= kk <= 1:
                weight = wght(ii, x)*wght(jj, y)*wght(kk, z)
                for LL from 0 <= LL < last_d:
                    result[LL] += data[x_ind+ii,y_ind+jj,z_ind+kk,LL]*weight
    return result

cdef float wght(int i, float r):
    if i:
        return r
    else:
        return 1.-r

@cython.boundscheck(False)
@cython.wraparound(False)
def _robust_peaks(cnp.ndarray[cnp.float_t, ndim=2] peak_vertices,
                  cnp.ndarray[cnp.float_t, ndim=1] peak_values,
                  float min_relative_value, float closest_neighbor):
    """Faster version of shm._robust_peaks
    """
    """some assumptions,
    1)  peak_values are sorted largest to smallest
    2)  peak_vetices are unit vectors
    3)  closest neighbor is cos(angle) where angle is smallest permiisible
        angle between between two robust peaks
    """
    if peak_vertices.shape[1] != 3:
        raise ValueError()
    cdef:
        cnp.ndarray[cnp.float_t, ndim=1] inst
        float min_value = peak_values[0] * min_relative_value
        float a, b, c
        int ii
    if len(peak_vertices) == 1:
        return peak_vertices

    good_peak_vertices = [peak_vertices[0]]
    for ii from 1 <= ii < len(peak_values):
        if peak_values[ii] < min_value:
            break
        a = peak_vertices[ii,0]
        b = peak_vertices[ii,1]
        c = peak_vertices[ii,2]
        t = 1
        for inst in good_peak_vertices:
            dist = a*inst[0] + b*inst[1] + c*inst[2]
            if fabs(dist) > closest_neighbor:
                t = 0
                break
        if t:
            good_peak_vertices.append(peak_vertices[ii])

    good_peak_vertices = np.array(good_peak_vertices)
    return good_peak_vertices

#@cython.boundscheck(False)
@cython.wraparound(False)
def peak_finding_onedge(odf, edges):
    """Given a function, odf, and neighbor pairs, edges, finds the local maxima

    If a function is evaluated on some set of points where each pair of
    neighboring points is in edges, the function compares each pair of
    neighbors and returns the value and location of each point that is >= all
    its neighbors.

    Parameters
    ----------
    odf : array_like
        The odf of some function evaluated at some set of points
    edges : array_like (N, 2)
        every edges(i,:) is a pair of neighboring points

    Returns
    -------
    peaks : ndarray
        odf at local maximums, orders the peaks in descending order
    inds : ndarray
        location of local maximums, indexes to odf array so that
        odf[inds[i]] == peaks[i]

    Note
    ----
    Comparing on edges might be faster then comparing on faces if edges does
    not contain repeated entries. Additionally in the event that some function
    is symmetric in some way, that symmetry can be exploited to further reduce
    the domain of the search and the number of input edges. This is done in the
    create_half_unit_sphere function of dipy.core.triangle_subdivide for
    functions with antipodal symmetry.

    See Also
    --------
    create_half_unit_sphere

    """

    cdef:
        cnp.ndarray[cnp.uint16_t, ndim=2] cedges = np.ascontiguousarray(edges)
        cnp.ndarray[cnp.float64_t, ndim=1] codf = np.ascontiguousarray(odf)
        cnp.ndarray[cnp.uint8_t, ndim=1] cpeak = np.ones(len(odf), 'uint8')
        int i=0
        int lenedges = len(cedges)
        int find0, find1
        double odf0, odf1

    for i from 0 <= i < lenedges:

        find0 = cedges[i,0]
        find1 = cedges[i,1]

        odf0 = codf[find0]
        odf1 = codf[find1]

        if odf0 > odf1:
            cpeak[find1] = 0
        elif odf0 < odf1:
            cpeak[find0] = 0

    cpeak = np.array(cpeak)

    #find local maxima and give fiber orientation (inds) and magnitude
    #peaks in a descending order

    inds = cpeak.nonzero()[0]
    pinds = odf[inds].argsort()
    inds = inds[pinds][::-1]
    peaks = odf[inds]

    return peaks, inds

@cython.boundscheck(False)
@cython.wraparound(False)
def peak_finding(odf, odf_faces):
    ''' Hemisphere local maxima from sphere values and faces

    Return local maximum values and indices. Local maxima (peaks) are
    given in descending order.

    The sphere mesh, as defined by the vertex coordinates ``vertices``
    and the face indices ``odf_faces``, has to conform to the check in
    ``dipy.core.meshes.peak_finding_compatible``.  If it does not, then
    the results from peak finding routine will be unpredictable.

    Parameters
    ------------
    odf : (N,) array of dtype np.float64
       function values on the sphere, where N is the number of vertices
       on the sphere
    odf_faces : (M,3) array of dtype np.uint16
       faces of the triangulation on the sphere, where M is the number
       of faces on the sphere

    Returns
    ---------
    peaks : (L,) array, dtype np.float64
       peak values, shape (L,) where L can vary and is the number of
       local moximae (peaks).  Values are sorted, largest first
    inds : (L,) array, dtype np.uint16
       indices of the peak values on the `odf` array corresponding to
       the maxima in `peaks`
    
    Notes
    -----
    In summary this function does the following:

    Where the smallest odf values in the vertices of a face put
    zeros on them. By doing that for the vertices of all faces at the
    end you only have the peak points with nonzero values.

    For precalculated odf_faces look under
    dipy/data/evenly*.npz to use them try numpy.load()['faces']
    
    Examples
    ----------
    This is called from GeneralizedQSampling or QBall and other models with orientation
    distribution functions.

    See also
    -----------
    dipy.core.meshes
    '''
    cdef:
        cnp.ndarray[cnp.uint16_t, ndim=2] cfaces = np.ascontiguousarray(odf_faces)
        cnp.ndarray[cnp.float64_t, ndim=1] codf = np.ascontiguousarray(odf)
        cnp.ndarray[cnp.float64_t, ndim=1] cpeak = odf.copy()
        int i=0
        int test=0
        int lenfaces = len(cfaces)
        double odf0,odf1,odf2
        int find0,find1,find2
    
    for i in range(lenfaces):

        find0 = cfaces[i,0]
        find1 = cfaces[i,1]
        find2 = cfaces[i,2]        
        
        odf0=codf[find0]
        odf1=codf[find1]
        odf2=codf[find2]       

        if odf0 >= odf1 and odf0 >= odf2:
            cpeak[find1] = 0
            cpeak[find2] = 0
            continue

        if odf1 >= odf0 and odf1 >= odf2:
            cpeak[find0] = 0
            cpeak[find2] = 0
            continue

        if odf2 >= odf0 and odf2 >= odf1:
            cpeak[find0] = 0
            cpeak[find1] = 0
            continue

    peak=np.array(cpeak)
    peak=peak[0:len(peak)/2]

    #find local maxima and give fiber orientation (inds) and magnitude
    #peaks in a descending order

    inds=np.where(peak>0)[0]
    pinds=np.argsort(peak[inds])
    peaks=peak[inds[pinds]][::-1]

    return peaks, inds[pinds][::-1]

@cython.boundscheck(False)
@cython.wraparound(False)
def pdf_to_odf(cnp.ndarray[double, ndim=1] odf, \
                 cnp.ndarray[double, ndim=1] PrIs,\
                 cnp.ndarray[double, ndim=1] radius,\
                 int odfn,int radiusn):
    """ Expecting interpolated pdf then calculates the odf for that pdf
    """    
    cdef int m,i
    
    with nogil:
        for m in range(odfn):
            for i in range(radiusn):
                odf[m]=odf[m]+PrIs[m*radiusn+i]*radius[i]*radius[i]

    return

@cython.boundscheck(False)
@cython.wraparound(False)
def le_to_odf(cnp.ndarray[double, ndim=1] odf, \
                 cnp.ndarray[double, ndim=1] LEs,\
                 cnp.ndarray[double, ndim=1] radius,\
                 int odfn,\
                 int radiusn,\
                 int anglesn):
    """ Expecting interpolated laplacian normalized signal and  then calculates the odf for that.
    """    
    cdef int m,i,j    
    
    with nogil:    
        for m in range(odfn):
            for i in range(radiusn):
                for j in range(anglesn):
                    odf[m]=odf[m]-LEs[(m*radiusn+i)*anglesn+j]*radius[i]

    return

@cython.boundscheck(False)
@cython.wraparound(False)
def sum_on_blocks_1d(cnp.ndarray[double, ndim=1] arr,\
    cnp.ndarray[long, ndim=1] blocks,\
    cnp.ndarray[double, ndim=1] out,int outn):
    """ Summations on blocks of 1d array
    
    """
    cdef:
        int m,i,j
        double sum    
	
    with nogil:
        j=0
        for m in range(outn):    		
            sum=0
            for i in range(j,j+blocks[m]):
                sum+=arr[i]
            out[m]=sum
            j+=blocks[m]
    return

def argmax_from_adj(vals, vertex_inds, adj_inds):
    """ Indices of local maxima from `vals` given adjacent points

    Parameters
    ------------
    vals : (N,) array, dtype np.float64
       values at all vertices referred to in either of `vertex_inds` or
       `adj_inds`'
    vertex_inds : (V,) array
       indices into `vals` giving vertices that may be local maxima.
    adj_inds : sequence
       For every vertex in ``vertex_inds``, the indices (into `vals`) of
       the neighboring points

    Returns
    ---------
    inds : (M,) array
       Indices into `vals` giving local maxima of vals, given topology
       from `adj_inds`, and restrictions from `vertex_inds`.  Inds are
       returned sorted by value at that index - i.e. smallest value (at
       index) first.
    """
    cvals, cvertinds = proc_reco_args(vals, vertex_inds)
    cadj_counts, cadj_inds = adj_to_countarrs(adj_inds)
    return argmax_from_countarrs(cvals, cvertinds, cadj_counts, cadj_inds)


def proc_reco_args(vals, vertinds):
    vals = np.ascontiguousarray(vals.astype(np.float))
    vertinds = np.ascontiguousarray(vertinds.astype(np.uint32))
    return vals, vertinds


def adj_to_countarrs(adj_inds):
    """ Convert adjacency sequence to counts and flattened indices

    We use this to provide expected input to ``argmax_from_countarrs``

    Parameters
    ------------
    adj_indices : sequence
       length V sequence of sequences, where sequence ``i`` contains the
       neighbors of a particular vertex.

    Returns
    ---------
    counts : (V,) array
       Number of neighbors for each vertex
    adj_inds : (n,) array
       flat array containing `adj_indices` unrolled as a vector
    """
    counts = []
    all_inds = []
    for verts in adj_inds:
        v = list(verts)
        all_inds += v
        counts.append(len(v))
    adj_inds = np.array(all_inds, dtype=np.uint32)
    counts = np.array(counts, dtype=np.uint32)
    return counts, adj_inds


# prefetch argsort for small speedup
cdef object argsort = np.argsort


def argmax_from_countarrs(cnp.ndarray vals,
                          cnp.ndarray vertinds,
                          cnp.ndarray adj_counts,
                          cnp.ndarray adj_inds):
    """ Indices of local maxima from `vals` from count, array neighbors

    Parameters
    ------------
    vals : (N,) array, dtype float
       values at all vertices referred to in either of `vertex_inds` or
       `adj_inds`'
    vertinds : (V,) array, dtype uint32
       indices into `vals` giving vertices that may be local maxima.
    adj_counts : (V,) array, dtype uint32
       For every vertex ``i`` in ``vertex_inds``, the number of
       neighbors for vertex ``i``
    adj_inds : (P,) array, dtype uint32
       Indices for neighbors for each point.  ``P=sum(adj_counts)`` 

    Returns
    ---------
    inds : (M,) array
       Indices into `vals` giving local maxima of vals, given topology
       from `adj_counts` and `adj_inds`, and restrictions from
       `vertex_inds`.  Inds are returned sorted by value at that index -
       i.e. smallest value (at index) first.
    """
    cdef:
        cnp.ndarray[cnp.float64_t, ndim=1] cvals = vals
        cnp.ndarray[cnp.uint32_t, ndim=1] cvertinds = vertinds
        cnp.ndarray[cnp.uint32_t, ndim=1] cadj_counts = adj_counts
        cnp.ndarray[cnp.uint32_t, ndim=1] cadj_inds = adj_inds
        # temporary arrays for storing maxes
        cnp.ndarray[cnp.float64_t, ndim=1] maxes = vals.copy()
        cnp.ndarray[cnp.uint32_t, ndim=1] maxinds = vertinds.copy()
        cnp.npy_intp i, j, V, C, n_maxes=0, adj_size, adj_pos=0
        int is_max
        cnp.float64_t *vals_ptr
        double val
        cnp.uint32_t vert_ind, *vertinds_ptr, *counts_ptr, *adj_ptr, ind
        cnp.uint32_t vals_size, vert_size
    if not (cnp.PyArray_ISCONTIGUOUS(cvals) and
            cnp.PyArray_ISCONTIGUOUS(cvertinds) and
            cnp.PyArray_ISCONTIGUOUS(cadj_counts) and
            cnp.PyArray_ISCONTIGUOUS(cadj_inds)):
        raise ValueError('Need contiguous arrays as input')
    vals_size = cvals.shape[0]
    vals_ptr = <cnp.float64_t *>cvals.data
    vertinds_ptr = <cnp.uint32_t *>cvertinds.data
    adj_ptr = <cnp.uint32_t *>cadj_inds.data
    counts_ptr = <cnp.uint32_t *>cadj_counts.data
    V = cadj_counts.shape[0]
    adj_size = cadj_inds.shape[0]
    if cvertinds.shape[0] < V:
        raise ValueError('Too few indices for adj arrays')
    for i in range(V):
        vert_ind = vertinds_ptr[i]
        if vert_ind >= vals_size:
            raise IndexError('Overshoot on vals')
        val = vals_ptr[vert_ind]
        C = counts_ptr[i]
        # check for overshoot
        adj_pos += C
        if adj_pos > adj_size:
            raise IndexError('Overshoot on adj_inds array')
        is_max = 1
        for j in range(C):
            ind = adj_ptr[j]
            if ind >= vals_size:
                raise IndexError('Overshoot on vals')
            if val <= vals_ptr[ind]:
                is_max = 0
                break
        if is_max:
            maxinds[n_maxes] = vert_ind
            maxes[n_maxes] = val
            n_maxes +=1
        adj_ptr += C
    if n_maxes == 0:
        return np.array([])
    # fancy indexing always produces a copy
    return maxinds[argsort(maxes[:n_maxes])]

