!**************************************************************
!  Copyright INRIA
!  Authors : 
!     CALVI project team
!  
!  This code SeLaLib (for Semi-Lagrangian-Library) 
!  is a parallel library for simulating the plasma turbulence 
!  in a tokamak.
!  
!  This software is governed by the CeCILL-B license 
!  under French law and abiding by the rules of distribution 
!  of free software.  You can  use, modify and redistribute 
!  the software under the terms of the CeCILL-B license as 
!  circulated by CEA, CNRS and INRIA at the following URL
!  "http://www.cecill.info". 
!**************************************************************

module sll_vlasov4d_polar

#define MPI_MASTER 0
#include "sll_working_precision.h"
#include "sll_memory.h"
#include "sll_assert.h"

use sll_m_collective
use sll_m_interpolators_1d_base
use sll_m_interpolators_2d_base
use sll_m_remapper
use sll_vlasov4d_base
use sll_m_gnuplot_parallel
use sll_m_cartesian_meshes
use sll_m_common_coordinate_transformations
use sll_m_coordinate_transformation_2d_base
use sll_m_coordinate_transformations_2d
use sll_m_cubic_spline_interpolator_2d

use iso_fortran_env, only: output_unit

implicit none

!> vp4d polar simulation class extended from sll_simulation_base_class
type, public, extends(vlasov4d_base) :: vlasov4d_polar
  
 sll_int32  :: nc_x1, nc_x2, nc_x3, nc_x4 !< Mesh parameters
 class(sll_c_coordinate_transformation_2d_base), pointer :: transfx !< transformation
 sll_real64, dimension(:,:), pointer :: proj_f_x1x2 !< f projection to x1x2
 sll_real64, dimension(:,:), pointer :: proj_f_x3x4 !< f projection to x3x4

 class(sll_c_interpolator_2d), pointer :: interp_x1x2 !< interpolator 2d in xy
 class(sll_c_interpolator_1d), pointer :: interp_x3   !< interpolator 1d in vx
 class(sll_c_interpolator_1d), pointer :: interp_x4   !< interpolator 1d in vx

 sll_real64, dimension(:),     pointer :: params   !< function initializer parameters
 sll_real64, dimension(:,:),   pointer :: x1       !< x1 mesh mapped coordinates
 sll_real64, dimension(:,:),   pointer :: x2       !< x2 mesh mapped coordinates
 sll_real64, dimension(:,:),   pointer :: phi_x1   !< potential
 sll_real64, dimension(:,:),   pointer :: phi_x2   !< potential
 sll_real64, dimension(:,:,:), pointer :: partial_reduction
 sll_real64, dimension(:,:,:), pointer :: efields_x1
 sll_real64, dimension(:,:,:), pointer :: efields_x2


 type(sll_t_layout_2d), pointer :: layout_x1 ! sequential in r direction
 type(sll_t_layout_2d), pointer :: layout_x2 ! sequential in theta direction
 type(sll_t_remap_plan_2D_real64), pointer :: rmp_x1x2   !< remap r->theta 
 type(sll_t_remap_plan_2D_real64), pointer :: rmp_x2x1   !< remap theta->r

end type vlasov4d_polar

!> Local variables
sll_int32,  private :: i, j, k, l
sll_int32,  private :: loc_sz_x1, loc_sz_x2, loc_sz_x3, loc_sz_x4 
sll_int32,  private :: global_indices(4)
sll_int32,  private :: gi, gj, gk, gl
sll_real64, private :: alpha1, alpha2, alpha3, alpha4
sll_real64, private :: eta1, eta2, eta3, eta4
sll_real64, private :: jac_m(2,2), inv_j(2,2)
sll_int32,  private :: error

sll_int32,  public  :: itime, prank, psize

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
contains
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

subroutine initialize_vp4d_polar( this,        &
                                  interp_x1x2, &
                                  interp_x3,   &
                                  interp_x4)

  type(vlasov4d_polar), intent(inout)     :: this

  class(sll_c_interpolator_2d), target :: interp_x1x2
  class(sll_c_interpolator_1d), target :: interp_x3
  class(sll_c_interpolator_1d), target :: interp_x4

  psize = sll_f_get_collective_size(sll_v_world_collective)
  prank = sll_f_get_collective_rank(sll_v_world_collective)

  this%interp_x1x2 => interp_x1x2
  this%interp_x3   => interp_x3
  this%interp_x4   => interp_x4

  this%transposed = .false.

  this%layout_x => sll_f_new_layout_4d( sll_v_world_collective )        

  call sll_o_initialize_layout_with_distributed_array( &
            this%nc_eta1+1, this%nc_eta2+1, this%nc_eta3+1, this%nc_eta4+1,    &
            1,1,int(psize,4),1,this%layout_x)

  if ( prank == MPI_MASTER ) call sll_o_view_lims( this%layout_x )
  flush( output_unit )

  call sll_o_compute_local_sizes(this%layout_x, &
                              loc_sz_x1,loc_sz_x2,loc_sz_x3,loc_sz_x4)        
  SLL_CLEAR_ALLOCATE(this%f(1:loc_sz_x1,1:loc_sz_x2,1:loc_sz_x3,1:loc_sz_x4),error)

  this%layout_v => sll_f_new_layout_4d( sll_v_world_collective )
  call sll_o_initialize_layout_with_distributed_array( &
              this%nc_eta1+1, this%nc_eta2+1, this%nc_eta3+1, this%nc_eta4+1,    &
              int(psize,4),1,1,1,this%layout_v)

  if ( prank == MPI_MASTER ) call sll_o_view_lims( this%layout_v )
  flush( output_unit )

  call sll_o_compute_local_sizes(this%layout_v, &
                              loc_sz_x1,loc_sz_x2,loc_sz_x3,loc_sz_x4)        
  SLL_CLEAR_ALLOCATE(this%ft(1:loc_sz_x1,1:loc_sz_x2,1:loc_sz_x3,1:loc_sz_x4),error)

  this%x_to_v => sll_o_new_remap_plan( this%layout_x, this%layout_v, this%f)     
  this%v_to_x => sll_o_new_remap_plan( this%layout_v, this%layout_x, this%ft)     
  
  this%transfx => sll_f_new_coordinate_transformation_2d_analytic( &
       "analytic_polar_transformation", &
       this%geomx, &
       sll_f_polar_x1, &
       sll_f_polar_x2, &
       sll_f_polar_jac11, &
       sll_f_polar_jac12, &
       sll_f_polar_jac21, &
       sll_f_polar_jac22, (/0.0_f64/) )

  this%nc_x1 = this%geomx%num_cells1
  this%nc_x2 = this%geomx%num_cells2
  this%nc_x3 = this%geomv%num_cells1
  this%nc_x4 = this%geomv%num_cells2

  call sll_o_compute_local_sizes( this%layout_x, &
         loc_sz_x1, loc_sz_x2, loc_sz_x3, loc_sz_x4 )

  SLL_ALLOCATE(this%proj_f_x3x4(loc_sz_x3,loc_sz_x4),error)

  call sll_o_compute_local_sizes( this%layout_v, &
         loc_sz_x1, loc_sz_x2, loc_sz_x3, loc_sz_x4 )

  SLL_ALLOCATE(this%proj_f_x1x2(loc_sz_x1,loc_sz_x2),error)
    
  this%layout_x1 => sll_f_new_layout_2d( sll_v_world_collective )

  call sll_o_initialize_layout_with_distributed_array( this%nc_x1+1, &
                                                    this%nc_x2+1, &
                                                    1,            &
                                                    psize,        &
                                                    this%layout_x1 )

  call sll_o_compute_local_sizes(this%layout_x1, loc_sz_x1, loc_sz_x2)

  SLL_CLEAR_ALLOCATE(this%phi_x1(1:loc_sz_x1,1:loc_sz_x2),error)
  SLL_CLEAR_ALLOCATE(this%efields_x1(1:loc_sz_x1,1:loc_sz_x2,2),error)

  this%layout_x2 => sll_f_new_layout_2d( sll_v_world_collective )

  call sll_o_initialize_layout_with_distributed_array( this%nc_x1+1, &
                                                    this%nc_x2+1, &
                                                    psize,       &
                                                    1,           &
                                                    this%layout_x2 )

  call sll_o_compute_local_sizes(this%layout_x2, loc_sz_x1, loc_sz_x2)

  SLL_CLEAR_ALLOCATE(this%rho(1:loc_sz_x1,1:loc_sz_x2),error)
  SLL_CLEAR_ALLOCATE(this%phi_x2(1:loc_sz_x1,1:loc_sz_x2),error)
  SLL_CLEAR_ALLOCATE(this%efields_x2(1:loc_sz_x1,1:loc_sz_x2,2),error)

  this%rmp_x1x2 => sll_o_new_remap_plan(this%layout_x1, this%layout_x2, this%phi_x1)
  this%rmp_x2x1 => sll_o_new_remap_plan(this%layout_x2, this%layout_x1, this%phi_x2)

  SLL_CLEAR_ALLOCATE(this%x1(1:loc_sz_x1,1:loc_sz_x2),error)
  SLL_CLEAR_ALLOCATE(this%x2(1:loc_sz_x1,1:loc_sz_x2),error)

  call sll_o_view_lims( this%layout_x2 )

  do j=1,loc_sz_x2
     do i=1,loc_sz_x1

        global_indices(1:2) = sll_o_local_to_global(this%layout_x2,(/i,j/))
        this%x1(i,j) = this%transfx%x1_at_node(global_indices(1),global_indices(2))
        this%x2(i,j) = this%transfx%x2_at_node(global_indices(1),global_indices(2))

     end do
  end do


  end subroutine initialize_vp4d_polar

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine advection_x1x2(this,deltat)

    class(vlasov4d_polar) :: this
    sll_real64, intent(in) :: deltat

    call sll_o_compute_local_sizes( this%layout_x, &
         loc_sz_x1, loc_sz_x2, loc_sz_x3, loc_sz_x4 )

    do l=1,loc_sz_x4
       do k=1,loc_sz_x3
          call this%interp_x1x2%compute_interpolants(this%f(:,:,k,l))
          do j=1,loc_sz_x2
             do i=1,loc_sz_x1
                global_indices = sll_o_local_to_global(this%layout_x,(/i,j,k,l/))
                gi = global_indices(1)
                gj = global_indices(2)
                gk = global_indices(3)
                gl = global_indices(4)
                eta1 = this%eta1_min + (gi-1)*this%delta_eta1
                eta2 = this%eta2_min + (gj-1)*this%delta_eta2
                eta3 =  eta1*sin(eta2) !this%mesh2d_v%eta1_min + (gk-1)*delta_eta3
                eta4 = -eta1*cos(eta2) !this%mesh2d_v%eta2_min + (gl-1)*delta_eta4
                inv_j  = this%transfx%inverse_jacobian_matrix(eta1,eta2)
                alpha1 = -deltat*(inv_j(1,1)*eta3 + inv_j(1,2)*eta4)
                alpha2 = -deltat*(inv_j(2,1)*eta3 + inv_j(2,2)*eta4)

                eta1 = eta1+alpha1
                ! This is hardwiring the periodic BC, please improve this...
                if( eta1 < this%eta1_min ) then
                   eta1 = eta1+this%eta1_max-this%eta1_min
                else if( eta1 > this%eta1_max ) then
                   eta1 = eta1+this%eta1_min-this%eta1_max
                end if

                eta2 = eta2+alpha2
                if( eta2 < this%eta2_min ) then
                   eta2 = eta2+this%eta2_max-this%eta2_min
                else if( eta2 > this%eta2_max ) then
                   eta2 = eta2+this%eta2_min-this%eta2_max
                end if
                
                this%f(i,j,k,l) = this%interp_x1x2%interpolate_from_interpolant_value( eta1, eta2)
             end do
          end do
       end do
    end do

  end subroutine advection_x1x2

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine advection_x3(this,deltat)

    class(vlasov4d_polar) :: this
    sll_real64, intent(in) :: deltat
    sll_real64 :: ex, ey

    call sll_o_compute_local_sizes( this%layout_v, &
            loc_sz_x1, loc_sz_x2, loc_sz_x3, loc_sz_x4 ) 

    do l=1,loc_sz_x4
       do j=1,loc_sz_x2
          do i=1,loc_sz_x1
             global_indices = sll_o_local_to_global( this%layout_v, (/i,j,1,1/))
             eta1   =  this%eta1_min + (global_indices(1)-1)*this%delta_eta1
             eta2   =  this%eta2_min + (global_indices(2)-1)*this%delta_eta2
             inv_j  =  this%transfx%inverse_jacobian_matrix(eta1,eta2)
             jac_m  =  this%transfx%jacobian_matrix(eta1,eta2)
             ex     =  this%efields_x2(i,j,1)
             ey     =  this%efields_x2(i,j,2)
             alpha3 = -deltat*(inv_j(1,1)*ex + inv_j(2,1)*ey)
             call this%interp_x3%interpolate_array_disp_inplace( &
                                   loc_sz_x3, this%ft(i,j,:,l), alpha3 )
          end do
       end do
    end do

  end subroutine advection_x3

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine advection_x4(this,deltat)

    class(vlasov4d_polar) :: this
    sll_real64, intent(in) :: deltat
    sll_real64 :: ex, ey

    call sll_o_compute_local_sizes( this%layout_v, &
         loc_sz_x1, loc_sz_x2, loc_sz_x3, loc_sz_x4 ) 

    do j=1,loc_sz_x2
       do i=1,loc_sz_x1
          do k=1,loc_sz_x3
             global_indices = sll_o_local_to_global( this%layout_v, (/i,j,1,1/))
             eta1   =  this%eta1_min+(global_indices(1)-1)*this%delta_eta1
             eta2   =  this%eta2_min+(global_indices(2)-1)*this%delta_eta2
             inv_j  =  this%transfx%inverse_jacobian_matrix(eta1,eta2)
             ex     =  this%efields_x2(i,j,1)
             ey     =  this%efields_x2(i,j,2)
             alpha4 = -deltat*(inv_j(1,2)*ex + inv_j(2,2)*ey)
             call this%interp_x4%interpolate_array_disp_inplace( &
                                   loc_sz_x4, this%ft(i,j,k,:), alpha4 )
          end do
       end do
    end do

  end subroutine advection_x4

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine plot_f(this)
    class(vlasov4d_polar) :: this


    call sll_o_compute_local_sizes( this%layout_v, &
         loc_sz_x1, loc_sz_x2, loc_sz_x3, loc_sz_x4 )

    do i = 1, loc_sz_x1
       do j = 1, loc_sz_x2
          this%proj_f_x1x2(i,j) = sum(this%ft(i,j,:,:))
       end do
    end do

    call sll_o_gnuplot_2d_parallel( this%x1, this%x2, this%proj_f_x1x2, &
                                  "fxy", itime, error )

  end subroutine plot_f

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine plot_ft(this)
    class(vlasov4d_polar) :: this

    call sll_o_compute_local_sizes( this%layout_x, &
         loc_sz_x1, loc_sz_x2, loc_sz_x3, loc_sz_x4 )

    do l = 1, loc_sz_x4
       do k = 1, loc_sz_x3
          this%proj_f_x3x4(k,l) = sum(this%f(:,:,k,l))
       end do
    end do

    call sll_o_gnuplot_2d_parallel( &
        this%eta3_min+(global_indices(1)-1)*this%delta_eta3, this%delta_eta3, &
        this%eta4_min+(global_indices(2)-1)*this%delta_eta4, this%delta_eta4, &
        size(this%proj_f_x3x4,1), size(this%proj_f_x3x4,2),                   & 
        this%proj_f_x3x4, "fvxvy", itime, error )

  end subroutine plot_ft

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine delete_vp4d_par_polar( this )

    type(vlasov4d_polar) :: this
    sll_int32 :: error

    SLL_DEALLOCATE( this%f, error )
    SLL_DEALLOCATE( this%ft, error )

    call sll_o_delete( this%layout_x )
    call sll_o_delete( this%layout_v )
    call sll_o_delete( this%x_to_v )
    call sll_o_delete( this%v_to_x )

  end subroutine delete_vp4d_par_polar

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine compute_charge_density( this )

    class(vlasov4d_polar) :: this

    call sll_o_compute_local_sizes(this%layout_v, &
                                loc_sz_x1,            &
                                loc_sz_x2,            &
                                loc_sz_x3,            &
                                loc_sz_x4)
    this%rho(:,:) = 0.0
    do j=1,loc_sz_x2
       do i=1,loc_sz_x1
          this%rho(i,j) = sum(this%ft(i,j,:,:))
       end do
    end do
    this%rho = this%rho *this%delta_eta3*this%delta_eta4

  end subroutine compute_charge_density

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  
  subroutine plot_rho(this)

    class(vlasov4d_polar) :: this

    call sll_o_compute_local_sizes(this%layout_x2, loc_sz_x1, loc_sz_x2)

    call sll_o_gnuplot_2d_parallel(this%x1, this%x2, this%rho, &
                                 'rho', itime, error)

  end subroutine plot_rho
 
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine plot_phi(this)

    class(vlasov4d_polar) :: this

    call sll_o_compute_local_sizes(this%layout_x2, loc_sz_x1, loc_sz_x2)

    call sll_o_gnuplot_2d_parallel(this%x1, this%x2, this%phi_x2, &
                                 'phi', itime, error)

  end subroutine plot_phi

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine compute_electric_fields_eta1( this )

    class(vlasov4d_polar) :: this

    sll_real64                        :: r_delta
    
    r_delta = 1.0_f64/this%delta_eta1
    
    i = 1
    this%efields_x1(i,:,1) = -r_delta*(- 1.5_f64*this%phi_x1(i  ,:) &
                                   + 2.0_f64*this%phi_x1(i+1,:) &
                                   - 0.5_f64*this%phi_x1(i+2,:) )
    i = this%nc_x1+1
    this%efields_x1(i,:,1) = -r_delta*(  0.5_f64*this%phi_x1(i-2,:) &
                                   - 2.0_f64*this%phi_x1(i-1,:) &
                                   + 1.5_f64*this%phi_x1(i  ,:) )
    do i=2, this%nc_x1
       this%efields_x1(i,:,1) = -r_delta*0.5_f64*(this%phi_x1(i+1,:) &
                                            - this%phi_x1(i-1,:))
    end do

    call sll_o_apply_remap_2D( this%rmp_x1x2, &
                         this%efields_x1(:,:,1), &
                         this%efields_x2(:,:,1) )

  end subroutine compute_electric_fields_eta1

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine compute_electric_fields_eta2( this )

    class(vlasov4d_polar) :: this
    sll_real64                        :: r_delta
  
    r_delta = 1.0_f64/this%delta_eta2
    
    j=1 
    this%efields_x2(:,j,2) = -r_delta*(- 1.5_f64*this%phi_x2(:,j)   &
                                     + 2.0_f64*this%phi_x2(:,j+1) &
                                     - 0.5_f64*this%phi_x2(:,j+2))
    j=this%nc_x2+1
    this%efields_x2(:,j,2) = -r_delta*(  0.5_f64*this%phi_x2(:,j-2) &
                                     - 2.0_f64*this%phi_x2(:,j-1) &
                                     + 1.5_f64*this%phi_x2(:,j))
    
    do j=2,this%nc_x2
       this%efields_x2(:,j,2) = -r_delta*0.5_f64*(this%phi_x2(:,j+1) &
                                              - this%phi_x2(:,j-1))
    end do

    call sll_o_apply_remap_2D( this%rmp_x2x1, &
                         this%efields_x2(:,:,2), &
                         this%efields_x1(:,:,2) )

  end subroutine compute_electric_fields_eta2

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

end module sll_vlasov4d_polar
