program vp4d

#include "selalib-mpi.h"

  use sll_vlasov4d_base
  use sll_vlasov4d_poisson
  use sll_m_gnuplot
  use init_functions

  implicit none

  type(vlasov4d_poisson)    :: vlasov4d 
  type(sll_t_poisson_2d_periodic_fft) :: poisson 

  type(sll_t_cubic_spline_interpolator_1d), target :: spl_x1
  type(sll_t_cubic_spline_interpolator_1d), target :: spl_x2
  type(sll_t_cubic_spline_interpolator_1d), target :: spl_x3
  type(sll_t_cubic_spline_interpolator_1d), target :: spl_x4

  sll_real64, dimension(:,:), allocatable :: phi

  sll_int32  :: iter
  sll_int32  :: prank, comm
  sll_int32  :: loc_sz_i, loc_sz_j, loc_sz_k, loc_sz_l
  sll_int64  :: psize
  sll_real64 :: tcpu1, tcpu2
  sll_int32  :: i,j,k,l,error
  sll_real64 :: vx,vy,v2,x,y
  sll_real64 :: kx, ky
  sll_int32  :: gi, gj, gk, gl
  sll_int32  :: global_indices(4)
  sll_real64 :: time

  call sll_s_boot_collective()

  prank = sll_f_get_collective_rank(sll_v_world_collective)
  psize = sll_f_get_collective_size(sll_v_world_collective)
  comm  = sll_v_world_collective%comm

  tcpu1 = MPI_WTIME()
  if (.not. sll_f_is_power_of_two(psize)) then     
     print *, 'This test needs to run in a number of processes which is ',&
          'a power of 2.'
     stop
  end if
  if (prank == MPI_MASTER) then
     print*,'MPI Version of slv2d running on ',psize, ' processors'
  end if

  call read_input_file(vlasov4d)

  call spl_x1%init(vlasov4d%nc_eta1+1,  &
                         vlasov4d%eta1_min,   &
                         vlasov4d%eta1_max,   &
                         sll_p_periodic)

  call spl_x2%init(vlasov4d%nc_eta2+1,  &
                         vlasov4d%eta2_min,   &
                         vlasov4d%eta2_max,   &
                         sll_p_periodic)

  call spl_x3%init(vlasov4d%nc_eta3+1,  &
                         vlasov4d%eta3_min,   &
                         vlasov4d%eta3_max,   &
                         sll_p_periodic)

  call spl_x4%init(vlasov4d%nc_eta4+1,  &
                         vlasov4d%eta4_min,   &
                         vlasov4d%eta4_max,   &
                         sll_p_periodic)

  call initialize(vlasov4d,spl_x1,spl_x2,spl_x3,spl_x4,error)

  call sll_o_compute_local_sizes(vlasov4d%layout_x, &
         loc_sz_i,loc_sz_j,loc_sz_k,loc_sz_l)        


  kx  = 2_f64*sll_p_pi/(vlasov4d%eta1_max-vlasov4d%eta1_min)
  ky  = 2_f64*sll_p_pi/(vlasov4d%eta2_max-vlasov4d%eta2_min)
    
  do l=1,loc_sz_l 
  do k=1,loc_sz_k
  do j=1,loc_sz_j
  do i=1,loc_sz_i

     global_indices = sll_o_local_to_global(vlasov4d%layout_x,(/i,j,k,l/)) 
     gi = global_indices(1)
     gj = global_indices(2)
     gk = global_indices(3)
     gl = global_indices(4)

     x  = vlasov4d%eta1_min+(gi-1)*vlasov4d%delta_eta1
     y  = vlasov4d%eta2_min+(gj-1)*vlasov4d%delta_eta2
     vx = vlasov4d%eta3_min+(gk-1)*vlasov4d%delta_eta3
     vy = vlasov4d%eta4_min+(gl-1)*vlasov4d%delta_eta4

     v2 = vx*vx+vy*vy

     vlasov4d%f(i,j,k,l) = landau_cos_prod(vlasov4d%eps,kx, ky, x, y, v2)

  end do
  end do
  end do
  end do

  call sll_o_initialize(poisson, &
             vlasov4d%eta1_min, vlasov4d%eta1_max, vlasov4d%nc_eta1, &
             vlasov4d%eta2_min, vlasov4d%eta2_max, vlasov4d%nc_eta2, error)

  time = 0.0_f64
  call advection_x1(vlasov4d,0.5*vlasov4d%dt)
  call advection_x2(vlasov4d,0.5*vlasov4d%dt)

  do iter=1, vlasov4d%nbiter

     if (iter == 1 .or. mod(iter, vlasov4d%fdiag) == 0) then 
        call write_xmf_file(vlasov4d,iter/ vlasov4d%fdiag)
     end if

     call transposexv(vlasov4d)

     call compute_charge(vlasov4d)
     
     call sll_o_solve(poisson,vlasov4d%ex,vlasov4d%ey,vlasov4d%rho)

     !call plot('rho')
     !call plot('phi')
     !call plot('ex')
     !call plot('ey')

     time = time + 0.5*vlasov4d%dt
     if (mod(iter, vlasov4d%fthdiag).eq.0) then 
        call write_energy(vlasov4d,time)
     end if

     call advection_x3(vlasov4d, vlasov4d%dt)
     call advection_x4(vlasov4d, vlasov4d%dt)

     call transposevx(vlasov4d)

     time = time + 0.5*vlasov4d%dt

     call advection_x1(vlasov4d, vlasov4d%dt)
     call advection_x2(vlasov4d, vlasov4d%dt)


  end do

  tcpu2 = MPI_WTIME()
  if (prank == MPI_MASTER) &
       write(*,"(//10x,' Wall time = ', G15.3, ' sec' )") (tcpu2-tcpu1)*psize

  call sll_s_halt_collective()

contains

   subroutine plot(fieldname)
   character(len=*), intent(in) :: fieldname

   select case(fieldname)
   case('rho')
     call sll_o_gnuplot_2d(vlasov4d%eta1_min, vlasov4d%eta1_max, &
                           vlasov4d%np_eta1, vlasov4d%eta2_min, &
                           vlasov4d%eta2_max, vlasov4d%np_eta2, &
                           vlasov4d%rho, fieldname, iter, error)  
   case('phi')
     call sll_o_gnuplot_2d(vlasov4d%eta1_min, vlasov4d%eta1_max, &
                           vlasov4d%np_eta1, vlasov4d%eta2_min, &
                           vlasov4d%eta2_max, vlasov4d%np_eta2, &
                           phi, fieldname, iter, error)  
   case('ex')
     call sll_o_gnuplot_2d(vlasov4d%eta1_min, vlasov4d%eta1_max, &
                           vlasov4d%np_eta1, vlasov4d%eta2_min, &
                           vlasov4d%eta2_max, vlasov4d%np_eta2, &
                           vlasov4d%ex, fieldname, iter, error)  
   case('ey')
     call sll_o_gnuplot_2d(vlasov4d%eta1_min, vlasov4d%eta1_max, &
                           vlasov4d%np_eta1, vlasov4d%eta2_min, &
                           vlasov4d%eta2_max, vlasov4d%np_eta2, &
                           vlasov4d%ey, fieldname, iter, error)  
   end select

   end subroutine plot

end program vp4d
