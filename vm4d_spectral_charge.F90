program vm4d_spectral_charge

#include "selalib-mpi.h"

use init_functions
use sll_vlasov4d_base
use sll_vlasov4d_spectral_charge
use sll_m_poisson_2d_periodic
use sll_m_maxwell_2d_pstd

implicit none

type(sll_t_maxwell_2d_pstd)     :: maxwell
type(sll_t_poisson_2d_periodic_fft) :: poisson 
type(vlasov4d_spectral_charge)  :: vlasov4d 

type(sll_t_cubic_spline_interpolator_2d), target :: spl_x3x4

sll_int32  :: iter 
sll_real64 :: tcpu1, tcpu2, mass0

sll_int32  :: prank, comm
sll_int64  :: psize

sll_int32  :: loc_sz_i, loc_sz_j, loc_sz_k, loc_sz_l

call sll_s_boot_collective()
prank = sll_f_get_collective_rank(sll_v_world_collective)
psize = sll_f_get_collective_size(sll_v_world_collective)
comm  = sll_v_world_collective%comm

tcpu1 = MPI_WTIME()
if (prank == MPI_MASTER) then
   print*,'MPI Version of slv2d running on ',psize, ' processors'
end if

call initlocal()

!f --> ft
call transposexv(vlasov4d)

call compute_charge(vlasov4d)
call sll_o_solve(poisson,vlasov4d%ex,vlasov4d%ey,vlasov4d%rho)

vlasov4d%exn=vlasov4d%ex
vlasov4d%eyn=vlasov4d%ey

!ft --> f
call transposevx(vlasov4d)

mass0=sum(vlasov4d%rho)*vlasov4d%delta_eta1*vlasov4d%delta_eta2

print *,'mass init',mass0

!###############
!TIME LOOP
!###############

do iter=1,vlasov4d%nbiter

   if (iter ==1 .or. mod(iter,vlasov4d%fdiag) == 0) then 
      call write_xmf_file(vlasov4d,iter/vlasov4d%fdiag)
   end if

   if ( vlasov4d%va == VA_VALIS .or. vlasov4d%va == VA_CLASSIC) then 

      !f --> ft, current (this%jx,this%jy), ft-->f
      call transposexv(vlasov4d)

      !compute this%jx, this%jy (zero average) at time tn
      call compute_current(vlasov4d)

      call transposevx(vlasov4d)

      !compute vlasov4d%bz=B^{n+1/2} from Ex^n, Ey^n, B^{n-1/2}  
      !!!!Attention initialisation B^{-1/2}

      vlasov4d%bzn=vlasov4d%bz
      call solve_faraday(vlasov4d%dt)  
      
      !compute vlasov4d%bzn=B^n=0.5(B^{n+1/2}+B^{n-1/2})          
      vlasov4d%bzn=0.5_f64*(vlasov4d%bz+vlasov4d%bzn)
      vlasov4d%exn=vlasov4d%ex
      vlasov4d%eyn=vlasov4d%ey
      
      !compute (vlasov4d%ex,vlasov4d%ey)=E^{n+1/2} from vlasov4d%bzn=B^n
      call solve_ampere(0.5_f64*vlasov4d%dt) 

      if (vlasov4d%va == VA_CLASSIC) then 

         vlasov4d%jx3=vlasov4d%jx
         vlasov4d%jy3=vlasov4d%jy

      endif

   endif

   !advec x + compute this%jx1
   call advection_x1(vlasov4d,0.5_f64*vlasov4d%dt)

   !advec y + compute this%jy1
   call advection_x2(vlasov4d,0.5_f64*vlasov4d%dt)

   call transposexv(vlasov4d)

   if (vlasov4d%va == VA_OLD_FUNCTION) then 

      !compute rho^{n+1}
      call compute_charge(vlasov4d)
      !compute E^{n+1} via Poisson
      call sll_o_solve(poisson,vlasov4d%ex,vlasov4d%ey,vlasov4d%rho)

   endif

   call advection_x3x4(vlasov4d,vlasov4d%dt)

   call transposevx(vlasov4d)

   !copy jy^{**}
   vlasov4d%jy=vlasov4d%jy1
   !advec y + compute this%jy1
   call advection_x2(vlasov4d,0.5_f64*vlasov4d%dt)
   
   !copy jx^*
   vlasov4d%jx=vlasov4d%jx1
   !advec x + compute this%jx1
   call advection_x1(vlasov4d,0.5_f64*vlasov4d%dt)

   if (vlasov4d%va == VA_VALIS) then 

      !compute the good jy current
      vlasov4d%jy=0.5_f64*(vlasov4d%jy+vlasov4d%jy1)
      !compute the good jx current
      vlasov4d%jx=0.5_f64*(vlasov4d%jx+vlasov4d%jx1)
      print *,'sum jx jy', &
         sum(vlasov4d%jx)*vlasov4d%delta_eta1*vlasov4d%delta_eta2, &
         sum(vlasov4d%jy)*vlasov4d%delta_eta1*vlasov4d%delta_eta2, &
         maxval(vlasov4d%jx), &
         maxval(vlasov4d%jy)

      !compute E^{n+1} from B^{n+1/2}, vlasov4d%jx, vlasov4d%jy, E^n
      vlasov4d%ex  = vlasov4d%exn
      vlasov4d%ey  = vlasov4d%eyn
      vlasov4d%bzn = vlasov4d%bz     
      
      call solve_ampere(vlasov4d%dt) 

      !copy ex and ey at t^n for the next loop
      vlasov4d%exn = vlasov4d%ex
      vlasov4d%eyn = vlasov4d%ey

   else if (vlasov4d%va == VA_CLASSIC) then 

      !f --> ft, current (this%jx,this%jy), ft-->f
      call transposexv(vlasov4d)
      !compute this%jx, this%jy (zero average) at time tn
      call compute_current(vlasov4d)

      call transposevx(vlasov4d)

      !compute J^{n+1/2}=0.5*(J^n+J^{n+1})
      vlasov4d%jy=0.5_f64*(vlasov4d%jy+vlasov4d%jy3)
      vlasov4d%jx=0.5_f64*(vlasov4d%jx+vlasov4d%jx3)

      !compute E^{n+1} from B^{n+1/2}, vlasov4d%jx, vlasov4d%jy, E^n
      vlasov4d%ex  = vlasov4d%exn
      vlasov4d%ey  = vlasov4d%eyn
      vlasov4d%bzn = vlasov4d%bz     
      
      call solve_ampere(vlasov4d%dt) 

      !copy ex and ey at t^n for the next loop
      vlasov4d%exn = vlasov4d%ex
      vlasov4d%eyn = vlasov4d%ey

   else if (vlasov4d%va == VA_VLASOV_POISSON) then 

      call transposexv(vlasov4d)
      !compute rho^{n+1}
      call compute_charge(vlasov4d)
      call transposevx(vlasov4d)

      !compute E^{n+1} via Poisson
      call sll_o_solve(poisson,vlasov4d%ex,vlasov4d%ey,vlasov4d%rho)

      !print *,'verif charge conservation', &
      !             maxval(vlasov4d%exn-vlasov4d%ex), &
      !             maxval(vlasov4d%eyn-vlasov4d%ey)
   
   else if (vlasov4d%va==VA_OLD_FUNCTION) then 

      !recompute the electric field at time (n+1) for diagnostics
      call transposexv(vlasov4d)
      !compute rho^{n+1}
      call compute_charge(vlasov4d)
      call transposevx(vlasov4d)
      !compute E^{n+1} via Poisson
      call sll_o_solve(poisson,vlasov4d%ex,vlasov4d%ey,vlasov4d%rho)
   endif

   if (mod(iter,vlasov4d%fthdiag) == 0) then 
      call write_energy(vlasov4d, iter*vlasov4d%dt)
   endif

end do

tcpu2 = MPI_WTIME()
if (prank == MPI_MASTER) then
     write(*,"(//10x,' Wall time = ', G15.3, ' sec' )") (tcpu2-tcpu1)*psize
end if

!call sll_o_delete(poisson)
call sll_s_halt_collective()

print*,'PASSED'

!####################################################################################

contains

!####################################################################################

subroutine initlocal()

  use init_functions
  
  sll_real64 :: vx,vy,v2,x,y
  sll_int32  :: i,j,k,l,error
  sll_real64 :: kx, ky
  sll_int32  :: gi, gj, gk, gl
  sll_int32, dimension(4) :: global_indices
  sll_int32 :: psize

  prank = sll_f_get_collective_rank(sll_v_world_collective)
  psize = sll_f_get_collective_size(sll_v_world_collective)
  comm  = sll_v_world_collective%comm

  call read_input_file(vlasov4d)

  call spl_x3x4%init(vlasov4d%np_eta3, vlasov4d%np_eta4,   & 
                           vlasov4d%eta3_min, vlasov4d%eta3_max, &
                           vlasov4d%eta4_min, vlasov4d%eta4_max, &
  &                        sll_p_periodic, sll_p_periodic)


  call initialize(vlasov4d,spl_x3x4,error)

  call sll_o_compute_local_sizes(vlasov4d%layout_x, &
                           loc_sz_i,loc_sz_j,loc_sz_k,loc_sz_l)        

  kx  = 2_f64*sll_p_pi/(vlasov4d%nc_eta1*vlasov4d%delta_eta1)
  ky  = 2_f64*sll_p_pi/(vlasov4d%nc_eta2*vlasov4d%delta_eta2)

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

              select case(vlasov4d%num_case)
              case(LANDAU_X_CASE)
                  vlasov4d%f(i,j,k,l)= landau_1d(vlasov4d%eps,kx,x,v2)
              case(LANDAU_Y_CASE)
                  vlasov4d%f(i,j,k,l)= landau_1d(vlasov4d%eps,ky,y,v2)
              case(LANDAU_COS_PROD_CASE)
                  vlasov4d%f(i,j,k,l)= landau_cos_prod(vlasov4d%eps,kx,ky,x,y,v2)
              case(LANDAU_COS_SUM_CASE)
                  vlasov4d%f(i,j,k,l)= landau_cos_sum(vlasov4d%eps,kx,ky,x,y,v2)
              case(TSI_CASE)
                  vlasov4d%f(i,j,k,l)= tsi(vlasov4d%eps,kx,x,vx,v2)
              end select
              
           end do
        end do
     end do
  end do
  
  call sll_s_maxwell_2d_pstd_init(maxwell, &
       vlasov4d%eta1_min, vlasov4d%eta1_max, vlasov4d%nc_eta1, &
       vlasov4d%eta2_min, vlasov4d%eta2_max, vlasov4d%nc_eta2, TE_POLARIZATION)
  
  call sll_o_initialize(poisson, &
       vlasov4d%eta1_min, vlasov4d%eta1_max, vlasov4d%nc_eta1, &
       vlasov4d%eta2_min, vlasov4d%eta2_max, vlasov4d%nc_eta2, error)
  
  
end subroutine initlocal

subroutine solve_ampere(dt)

  sll_real64, intent(in)    :: dt
  
  call sll_s_solve_ampere_2d_pstd(maxwell, vlasov4d%ex, vlasov4d%ey, &
              vlasov4d%bzn, dt, vlasov4d%jx, vlasov4d%jy)

end subroutine solve_ampere

subroutine solve_faraday(dt)

  sll_real64, intent(in)    :: dt
  
  call sll_s_solve_faraday_2d_pstd(maxwell, vlasov4d%exn, vlasov4d%eyn, vlasov4d%bz, dt)
  
end subroutine solve_faraday
  
end program vm4d_spectral_charge
