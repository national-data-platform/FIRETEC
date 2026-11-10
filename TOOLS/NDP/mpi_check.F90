!-------------------------------------------------------------------------
! MPI check used by TOOLS/NDP/install.sh
!
! Compiled with the MPI Fortran wrapper and run on every CPU. It proves that
! the 'mpi' module matches the compiler (as FIRETEC needs), and its 8 MB
! messages exercise the shared-memory transport and the settings in
! openmpi*.conf. install.sh expects rank 0 to print 'ranks=N sum=N(N+1)/2'.
!-------------------------------------------------------------------------
program ndp_mpi_check
  use mpi
  implicit none
  integer, parameter :: nbig = 2000000
  integer :: ierr, rank, nprocs, total
  real, allocatable :: a(:), b(:)

  call MPI_Init(ierr)
  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)

  ! Pass a large message around a ring
  allocate(a(nbig), b(nbig))
  a = real(rank)
  call MPI_Sendrecv(a, nbig, MPI_REAL, mod(rank + 1, nprocs), 1, &
                    b, nbig, MPI_REAL, mod(rank - 1 + nprocs, nprocs), 1, &
                    MPI_COMM_WORLD, MPI_STATUS_IGNORE, ierr)
  if (nint(b(nbig)) /= mod(rank - 1 + nprocs, nprocs)) call MPI_Abort(MPI_COMM_WORLD, 3, ierr)

  call MPI_Allreduce(rank + 1, total, 1, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, ierr)
  if (rank == 0) print '(a,i0,a,i0)', 'ranks=', nprocs, ' sum=', total
  call MPI_Finalize(ierr)
end program ndp_mpi_check
