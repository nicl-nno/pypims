// ======================================================================================
// Name                :    High-Performance Integrated Modelling System
// Description         :    This code pack provides a generic framework for developing 
//                          Geophysical CFD software. Legacy name: GeoClasses
// ======================================================================================
// Version             :    1.0.1 
// Author              :    Xilin Xia
// Create Time         :    2014/10/04
// Update Time         :    2020/04/26
// ======================================================================================
// LICENCE: GPLv3 
// ======================================================================================


/*!
\file urban_flood_simulator.cu
\brief Source file for component test

*/

#ifdef _WIN32
#include <direct.h>
// MSDN recommends against using getcwd & chdir names
#define cwd _getcwd
#define cd _chdir
#else
#include "unistd.h"
#define cwd getcwd
#define cd chdir
#endif

#include <iostream>
#include <cuda_runtime_api.h>
#include <cuda.h>
//Header file for barrier
#include "barrier.h"
#include <thread>
#include <functional>
//These header files are the primitive types
#include "Flag.h"
#include "Scalar.h"
#include "Vector.h"
#include "cuda_arrays.h"
//These header files are for the fields
#include "mapped_field.h"
#include "cuda_mapped_field.h"
//These header files are for finite volume mesh
#include "mesh_fv_reduced.h"
#include "mesh_interface.h"
#include "cuda_mesh_fv.h"
#include "mesh_fv_cartesian.h"
//These header files are for input and output
#include "gisAsciiMesh_reader.h"
#include "gmsh_reader.h"
#include "field_reader.h"
#include "cuda_simple_writer.h"
#include "cuda_backup_writer.h"
#include "cuda_gauges_writer.h"
#include "cuda_gisascii_writer.h"
//These header files are for shallow water equations advection
#include "cuda_advection_NSWEs.h"
//The header file for gradient
#include "cuda_gradient.h"
//The header file for limiter
#include "cuda_limiter.h"
//The header file for friction
#include "cuda_friction.h"
//The header file for infiltration
#include "cuda_infiltration.h"
//The header file for field algebra
#include "cuda_field_algebra.h"
//The header file for integrator
#include "cuda_integrators.h"
//The header file for device query
#include "cuda_device_query.h"
//data bank files
#include "cuda_data_bank.h"
//The header file for time controllinh
#include "cuda_adaptive_time_control.h"
#include <thrust/device_ptr.h>
#include <thrust/reduce.h>


//using the name space for GeoClasses
using namespace GC;

int run(const char* work_dir){

  if(cd(work_dir) == -1){
    printf("The working directory does not exist!/n");
  }

	//set up GPU device number
  //unsigned int device_list;
  std::ifstream device_setup_file("input/device_setup.dat");
  int device_id;
  if (device_setup_file.is_open()){
    device_setup_file >> device_id;
	  checkCuda(cudaSetDevice(device_id));
	  std::cout << "GPU " << device_id << " is choosen as the model device"<< std::endl;
  }
  else{
    deviceQuery();
  }

  Scalar dt_out = 0.5;
  Scalar backup_interval = 0.0;
  Scalar backup_time = 0.0;
  Scalar t_current = 0.0;
  Scalar t_out = 0.0;
  Scalar t_all = 0.0;
  Scalar t_small = 1e-10;

  //*******************Read times setup value from file

   std::ifstream times_setuo_file("input/times_setup.dat");
   if (!times_setuo_file) {
     std::cout << "Please input current time, total time, output time interval and backup interval" << std::endl;
     std::cin >> t_current >> t_all >> dt_out >> backup_interval;
   }
   else {
     Scalar _time;
     std::vector<Scalar> GPU_Time_Values;
     while (times_setuo_file >> _time) {
       GPU_Time_Values.push_back(_time);
     }
     t_current = GPU_Time_Values[0];
     t_all = GPU_Time_Values[1];
     dt_out = GPU_Time_Values[2];
     backup_interval = GPU_Time_Values[3];
     std::cout << "Current time: " << t_current << "s" << std::endl;
     std::cout << "Total time: " << t_all << "s" << std::endl;
     std::cout << "Output time interval: " << dt_out << "s" << std::endl;
     std::cout << "Backup interval: " << backup_interval << "s" << std::endl;
   }
  //********************************
  //*******************Read device setup value from file

    
  cuAdaptiveTimeControl2D time_controller(0.005, t_all, 0.5, t_current);

  while(t_out < t_current){
    t_out += dt_out;
  }

  while(backup_time < t_current){
    backup_time += backup_interval;
  }

  std::shared_ptr<unstructuredFvMesh>  mesh = std::make_shared<CartesianFvMesh>("input/mesh/DEM.txt");

  std::cout << "Read in mesh successfully" << std::endl;

  //creating mesh on device
  std::shared_ptr<cuUnstructuredFvMesh>  mesh_ptr_dev = std::make_shared<cuUnstructuredFvMesh>(fvMeshQueries(mesh));
  
  //Read in field data
  fvScalarFieldOnCell z_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "z"));
  fvScalarFieldOnCell h_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "h"));
  fvVectorFieldOnCell hU_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "hU"));
  fvScalarFieldOnCell manning_coef_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "manning"));

  //precipitation
  fvScalarFieldOnCell precipitation_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "precipitation"));

  //infiltration
  fvScalarFieldOnCell culmulative_depth_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "cumulative_depth"));
  fvScalarFieldOnCell hydraulic_conductivity_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "hydraulic_conductivity"));
  fvScalarFieldOnCell capillary_head_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "capillary_head"));
  fvScalarFieldOnCell water_content_diff_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "water_content_diff"));

  //sewer sink
  fvScalarFieldOnCell sewer_sink_host(fvMeshQueries(mesh), completeFieldReader("input/field/", "sewer_sink"));


  std::cout << "Read in field successfully" << std::endl;

  //h, z, hU
  cuFvMappedField<Scalar, on_cell> z_old(z_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> z(z_host,mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> h(h_host,mesh_ptr_dev);
  cuFvMappedField<Vector, on_cell> hU(hU_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> manning_coef(manning_coef_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> culmulative_depth(culmulative_depth_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> hydraulic_conductivity(hydraulic_conductivity_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> capillary_head(capillary_head_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> water_content_diff(water_content_diff_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> sewer_sink(sewer_sink_host, mesh_ptr_dev);
  fv::cuUnaryOn(sewer_sink, [] __device__(Scalar& a) -> Scalar{ return -1.0*a; });

  //maximum innundated depth
  cuFvMappedField<Scalar, on_cell> h_max(h, partial);

    //x and y components of hU
  cuFvMappedField<Scalar, on_cell> hUx(h, partial);
  cuFvMappedField<Scalar, on_cell> hUy(h, partial);

  //surface elevation eta
  cuFvMappedField<Scalar, on_cell> eta(h, partial);

  //creating gauges writer
  cuGaugesWriter<Scalar, on_cell> h_writer(fvMeshQueries(mesh), h, "input/field/gauges_pos.dat", "output/h_gauges.dat");
  cuGaugesWriter<Scalar, on_cell> eta_writer(fvMeshQueries(mesh), eta, "input/field/gauges_pos.dat", "output/eta_gauges.dat");
  cuGaugesWriter<Vector, on_cell> hU_writer(fvMeshQueries(mesh), hU, "input/field/gauges_pos.dat", "output/hU_gauges.dat");

  //precipitation
  cuFvMappedField<Scalar, on_cell> precipitation(precipitation_host, mesh_ptr_dev);

  //advections
  cuFvMappedField<Scalar, on_cell> h_advection(h, partial);
  cuFvMappedField<Vector, on_cell> hU_advection(hU, partial);

  //gradient
  cuFvMappedField<Vector, on_cell> z_gradient(hU, partial);
  fv::cuLimitedGradientCartesian(z, z_gradient);

  //gravity
  cuFvMappedField<Scalar, on_cell> gravity(h, partial);
  //setting gravity to single value 9.81
  fv::cuUnaryOn(gravity, [] __device__ (Scalar& a) -> Scalar{return 9.81;}); 

  //update boundary to current time
  z.update_time(time_controller.current(), 0.0);
  z.update_boundary_values();
  h.update_time(time_controller.current(), 0.0);
  h.update_boundary_values();
  hU.update_time(time_controller.current(), 0.0);
  hU.update_boundary_values();

  //ascii raster writer
  cuGisAsciiWriter raster_writer("input/mesh/DEM.txt");

  //write the initial profile
  fv::cuUnary(hU, hUx, [] __device__(Vector& a) -> Scalar{ return a.x; });
  fv::cuUnary(hU, hUy, [] __device__(Vector& a) -> Scalar{ return a.y; });
  raster_writer.write(h, "h", t_out);
  raster_writer.write(hUx, "hUx", t_out);
  raster_writer.write(hUy, "hUy", t_out);
  t_out += dt_out;
  
  //write initial depth
  raster_writer.write(h, "h", time_controller.current());

  int cnt = 0;

  //print current time
  std::cout << time_controller.current() << std::endl;

  auto momentum_filter = [] __device__(Vector& a, Scalar& b) ->Vector{
    if (b <= 1e-10){
      return Vector(0.0);
    }
    else{
      return a;
    }
  };

  auto mass_filter = [] __device__(Scalar& a) ->Scalar{
    if (a <= 1e-10){
      return 0.0;
    }
    else{
      return a;
    }
  };


  std::ofstream fout;
  fout.open("output/timestep_log.txt");

  double total_runtime = 0.0;
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  h.update_boundary_source("input/field/", "h");
  hU.update_boundary_source("input/field/", "hU");

  //Main loop
  do{

    cudaEventRecord(start);

    //calculate the surface elevation
    fv::cuBinary(h, z, eta, [] __device__ (Scalar& a, Scalar& b) -> Scalar{return a + b;});

    //calculate advection
    fv::cuAdvectionMSWEsCartesian(gravity, h, z, z_gradient, hU, h_advection, hU_advection); //SRM

    //multiply advection with -1
    fv::cuUnaryOn(h_advection, [] __device__ (Scalar& a) -> Scalar{return -1.0*a;});
    fv::cuUnaryOn(hU_advection, [] __device__ (Vector& a) -> Vector{return -1.0*a;});

    //integration
    fv::cuFrictionManningImplicit(time_controller.dt(), gravity, manning_coef, h, hU, hU_advection);
    hU.update_time(time_controller.current(), time_controller.dt());
    hU.update_boundary_values();
    fv::cuEulerIntegrator(h, h_advection, time_controller.dt(), time_controller.current());    

    //precipitation
    precipitation.update_time(time_controller.current(), 0.0);
    precipitation.update_data_values();
    fv::cuEulerIntegrator(h, precipitation, time_controller.dt(), time_controller.current());

    //infiltration
    fv::cuInfiltrationGreenAmpt(h, hydraulic_conductivity, capillary_head, water_content_diff, culmulative_depth, time_controller.dt());

    //sewer sink
    fv::cuEulerIntegrator(h, sewer_sink, time_controller.dt(), time_controller.current());
    fv::cuUnaryOn(h, mass_filter);    //avoid negative depth

    //update maximum depth
    fv::cuBinary(h_max, h, h_max, [] __device__(Scalar& a, Scalar b) -> Scalar{ return fmax(a, b); });

    //forwarding the time
    time_controller.forward();
    time_controller.updateByCFL(gravity, h, hU);

    //-----------Fuse for extremely small dt------------ There is a bug to be resolved herein
/*     if (time_controller.dt()<0.0001) {
      fv::cuUnary(hU, hUx, [] __device__(Vector& a) -> Scalar{ return a.x; });
      fv::cuUnary(hU, hUy, [] __device__(Vector& a) -> Scalar{ return a.y; });
      raster_writer.write(h, "h", t_out);
      raster_writer.write(hUx, "hUx", t_out);
      raster_writer.write(hUy, "hUy", t_out);
      printf("Fuse!!!\n");
      break;
    } */

    //-----------Causes stuck after after reaching the output interval------------
/*    if (time_controller.current() + time_controller.dt() > t_out){
      Scalar dt = t_out - time_controller.current();
      time_controller.set_dt(dt);
    } */

    if (cnt % 100 == 0){
      h_writer.write(time_controller.current());
      eta_writer.write(time_controller.current());
	    hU_writer.write(time_controller.current());
    }

    //print current time
    printf("%f\n", time_controller.current());
    fout << time_controller.current() << " " <<time_controller.dt() << std::endl;
    cnt++;


    fv::cuBinaryOn(hU, h, momentum_filter);


    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float elapsed_time = 0.0;
    cudaEventElapsedTime(&elapsed_time, start, stop);
    total_runtime += elapsed_time;

    if (time_controller.current() >= t_out - t_small){
      std::cout << "Writing output files" << std::endl;
      fv::cuUnary(hU, hUx, [] __device__(Vector& a) -> Scalar{ return a.x; });
      fv::cuUnary(hU, hUy, [] __device__(Vector& a) -> Scalar{ return a.y; });
      raster_writer.write(h, "h", t_out);
      raster_writer.write(hUx, "hUx", t_out);
      raster_writer.write(hUy, "hUy", t_out);
      t_out += dt_out;
    }
    

    if (time_controller.current() >= backup_time - t_small){
      std::cout << "Writing backup files" << std::endl;
      cuBackupWriter(h, "h_backup_", backup_time);
      cuBackupWriter(hU, "hU_backup_", backup_time);
      backup_time += backup_interval;
    }


  } while (!time_controller.is_end());

  printf("Writing maximum inundated depth.\n");
  raster_writer.write(h_max, "h_max", t_all);
  std::cout << "Total runtime " << total_runtime << "ms" << std::endl;

  return 0;

}

Scalar dt_out = 0.5;
Scalar backup_interval = 0.0;
Scalar backup_time = 0.0;
//Scalar cooldown_interval = 0.0;
//Scalar cooldown_time = 0.0;
Scalar t_current = 0.0;
Scalar t_out = 0.0;
Scalar t_all = 0.0;
Scalar t_small = 1e-8;

std::atomic<Scalar> dt_global(0.05);

void single_run(cuDataBank& bank, std::vector<int> device_list, unsigned int domain_id, spinning_barrier& barrier){

  Scalar _t_out = t_out;
  Scalar _backup_time = backup_time;
//  Scalar _cooldown_time = cooldown_time;

  int device_id = device_list[domain_id];
  printf("Domain ID:%d Device ID:%d\n", domain_id, device_id);

  checkCuda(cudaSetDevice(device_id));

  std::ostringstream directory_id;
  directory_id << domain_id;
  std::string DEM_file_name = directory_id.str() + "/input/mesh/DEM.txt";

  std::shared_ptr<unstructuredFvMesh>  mesh = std::make_shared<CartesianFvMesh>(DEM_file_name.c_str());

  printf("Read in DEM of domain %d successfully!\n", domain_id);

  //creating mesh on device
  std::shared_ptr<cuUnstructuredFvMesh>  mesh_ptr_dev = std::make_shared<cuUnstructuredFvMesh>(fvMeshQueries(mesh));

  std::string field_directory = directory_id.str() + "/input/field/";

  //Read in field data
  //Basics
  fvScalarFieldOnCell z_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "z"));
  fvScalarFieldOnCell h_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "h"));
  fvVectorFieldOnCell hU_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "hU"));
  fvScalarFieldOnCell manning_coef_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "manning"));

  //precipitation
  fvScalarFieldOnCell precipitation_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "precipitation"));

  //infiltration
  fvScalarFieldOnCell culmulative_depth_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "cumulative_depth"));
  fvScalarFieldOnCell hydraulic_conductivity_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "hydraulic_conductivity"));
  fvScalarFieldOnCell capillary_head_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "capillary_head"));
  fvScalarFieldOnCell water_content_diff_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "water_content_diff"));

  //sewer sink
  fvScalarFieldOnCell sewer_sink_host(fvMeshQueries(mesh), completeFieldReader(field_directory.c_str(), "sewer_sink"));

  printf("Read in field of domain %d successfully!\n", domain_id);

  //data on device------------------

  cuFvMappedField<Scalar, on_cell> z_old(z_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> z(z_host,mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> h(h_host,mesh_ptr_dev);
  cuFvMappedField<Vector, on_cell> hU(hU_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> manning_coef(manning_coef_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> culmulative_depth(culmulative_depth_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> hydraulic_conductivity(hydraulic_conductivity_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> capillary_head(capillary_head_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> water_content_diff(water_content_diff_host, mesh_ptr_dev);
  cuFvMappedField<Scalar, on_cell> sewer_sink(sewer_sink_host, mesh_ptr_dev);
  fv::cuUnaryOn(sewer_sink, [] __device__(Scalar& a) -> Scalar{ return -1.0*a; });

  //maximum innundated depth
  cuFvMappedField<Scalar, on_cell> h_max(h, partial);

  //x and y components of hU
  cuFvMappedField<Scalar, on_cell> hUx(h, partial);
  cuFvMappedField<Scalar, on_cell> hUy(h, partial);

  //water level
  cuFvMappedField<Scalar, on_cell> eta(h, partial);

  std::string output_directory = directory_id.str() + "/output/";

  //creating gauges writer
  cuGaugesWriter<Scalar, on_cell> h_writer(fvMeshQueries(mesh), h, (field_directory + "gauges_pos.dat").c_str(), 
    (output_directory +"h_gauges.dat").c_str());
  cuGaugesWriter<Scalar, on_cell> eta_writer(fvMeshQueries(mesh), eta, (field_directory + "gauges_pos.dat").c_str(), 
    (output_directory +"eta_gauges.dat").c_str());
  cuGaugesWriter<Vector, on_cell> hU_writer(fvMeshQueries(mesh), hU, (field_directory + "gauges_pos.dat").c_str(),
    (output_directory + "hU_gauges.dat").c_str());

  //precipitation
  cuFvMappedField<Scalar, on_cell> precipitation(precipitation_host, mesh_ptr_dev);

  //advections
  cuFvMappedField<Scalar, on_cell> h_advection(h, partial);
  cuFvMappedField<Vector, on_cell> hU_advection(hU, partial);

  //velocity
  cuFvMappedField<Vector, on_cell> u(hU, partial);  

  //exchange data
  CollectAndSend(z, bank, domain_id, device_list);
  ReceiveAndDispatch(z, bank, domain_id, device_list);

  //gradient
  cuFvMappedField<Vector, on_cell> z_gradient(hU, partial);
  fv::cuLimitedGradientCartesian(z, z_gradient);
  CollectAndSend(z_gradient, bank, domain_id, device_list);
  ReceiveAndDispatch(z_gradient, bank, domain_id, device_list);

  //gravity
  cuFvMappedField<Scalar, on_cell> gravity(h, partial);
  //setting gravity to single value 9.81
  fv::cuUnaryOn(gravity, [] __device__ (Scalar& a) -> Scalar{return 9.81;}); 

  cuAdaptiveTimeControl2D time_controller(0.005, t_all, 0.5, t_current);

  //update boundary to current time
  z.update_time(time_controller.current(), 0.0);
  z.update_boundary_values();
  h.update_time(time_controller.current(), 0.0);
  h.update_boundary_values();
  hU.update_time(time_controller.current(), 0.0);
  hU.update_boundary_values();

  //ascii raster writer
  cuGisAsciiWriter raster_writer(DEM_file_name.c_str());

  //write the initial profile
  fv::cuUnary(hU, hUx, [] __device__(Vector& a) -> Scalar{ return a.x; });
  fv::cuUnary(hU, hUy, [] __device__(Vector& a) -> Scalar{ return a.y; });
  raster_writer.write(h, "h", time_controller.current(), output_directory.c_str());
  raster_writer.write(hUx, "hUx", time_controller.current(), output_directory.c_str());
  raster_writer.write(hUy, "hUy", time_controller.current(), output_directory.c_str());

  int cnt = 0;
  
  //print current time
  if (domain_id == 0){
    printf("%f\n", time_controller.current());
  }
  
  auto momentum_filter = [] __device__(Vector& a, Scalar& b) ->Vector{
    if (b <= 1e-10){
      return Vector(0.0);
    }
    else{
      return a;
    }
  };

  auto mass_filter = [] __device__(Scalar& a) ->Scalar{
    if (a <= 1e-10){
      return 0.0;
    }
    else{
      return a;
    }
  };

  auto divide = [] __device__(Vector& a, Scalar& b) ->Vector{
    if (b <= 1e-10){
      return 0.0;
    }
    else{
      return a/b;
    }
  };

  //auto manning_filter= [] __device__(Scalar& a, Vector& b ) ->Scalar{
  //  if (norm(b) > 10.0){
  //    return 2.0*a;
  //  }
  //  else{
  //    return a;
  //  }
  //};

  h.update_boundary_source(field_directory.c_str(), "h");
  hU.update_boundary_source(field_directory.c_str(), "hU");

  std::ofstream fout;
  fout.open((output_directory + "timestep_log.txt").c_str());

  //Main loop
  do{

    //cudaEventRecord(start);

    //calculate the surface elevation
    fv::cuBinary(h, z, eta, [] __device__ (Scalar& a, Scalar& b) -> Scalar{return a + b;});

    //calculate advection
    fv::cuAdvectionMSWEsCartesian(gravity, h, z, z_gradient, hU, h_advection, hU_advection);

    //multiply advection with -1
    fv::cuUnaryOn(h_advection, [] __device__ (Scalar& a) -> Scalar{return -1.0*a;});
    fv::cuUnaryOn(hU_advection, [] __device__ (Vector& a) -> Vector{return -1.0*a;});

    //integration
    fv::cuFrictionManningImplicit(time_controller.dt(), gravity, manning_coef, h, hU, hU_advection);
    hU.update_time(time_controller.current(), time_controller.dt());
    hU.update_boundary_values();
    fv::cuEulerIntegrator(h, h_advection, time_controller.dt(), time_controller.current());    

    //precipitation
    precipitation.update_time(time_controller.current(), 0.0);
    precipitation.update_data_values();
    fv::cuEulerIntegrator(h, precipitation, time_controller.dt(), time_controller.current());

    //infiltration
    fv::cuInfiltrationGreenAmpt(h, hydraulic_conductivity, capillary_head, water_content_diff, culmulative_depth, time_controller.dt());

    //sewer sink
    fv::cuEulerIntegrator(h, sewer_sink, time_controller.dt(), time_controller.current());
    fv::cuUnaryOn(h, mass_filter);    //avoid negative depth

    //update maximum depth
    fv::cuBinary(h_max, h, h_max, [] __device__(Scalar& a, Scalar b) -> Scalar{ return fmax(a, b); });

    //modify manning coefficient to filter large velocities
    fv::cuBinary(hU, h, u, divide);
    //fv::cuBinary(manning_coef,u,manning_coef,manning_filter);

    ////forwarding the time
    time_controller.forward();

    if (cnt % 100 == 0){
      h_writer.write(time_controller.current());
      eta_writer.write(time_controller.current());
      hU_writer.write(time_controller.current());
    }

    //print current time
    if (domain_id == 0){
      printf("%f\n", time_controller.current());
      fout << time_controller.current() << " " << time_controller.dt() << std::endl;
    }

    cnt++;


    fv::cuBinaryOn(hU, h, momentum_filter);

    //exchange data
    CollectAndSend(h, bank, domain_id, device_list);
    ReceiveAndDispatch(h, bank, domain_id, device_list);
    CollectAndSend(hU, bank, domain_id, device_list);
    ReceiveAndDispatch(hU, bank, domain_id, device_list);
    CollectAndSend(culmulative_depth, bank, domain_id, device_list);
    ReceiveAndDispatch(culmulative_depth, bank, domain_id, device_list);

    time_controller.updateByCFL(gravity, h, hU);

    dt_global = std::min(dt_global.load(), time_controller.dt());

    barrier.wait();

    time_controller.set_dt(dt_global.load());

    barrier.wait();

    if (domain_id == 0){
      dt_global = 1e10;
    }

    barrier.wait();

    if (time_controller.current() + time_controller.dt() > _t_out){
      Scalar dt = _t_out - time_controller.current();
      time_controller.set_dt(dt);
    }

    if (time_controller.current() >= _t_out - t_small){
      printf("Writing output files\n");
      fv::cuUnary(hU, hUx, [] __device__(Vector& a) -> Scalar{ return a.x; });
      fv::cuUnary(hU, hUy, [] __device__(Vector& a) -> Scalar{ return a.y; });
      raster_writer.write(h, "h", _t_out, output_directory.c_str());
      raster_writer.write(hUx, "hUx", _t_out, output_directory.c_str());
      raster_writer.write(hUy, "hUy", _t_out, output_directory.c_str());
      _t_out += dt_out;
    }

    if (time_controller.current() >= _backup_time - t_small){
      printf("Writing backup files\n");
      cuBackupWriter(h, "h_backup_", _backup_time, output_directory.c_str());
      cuBackupWriter(hU, "hU_backup_", _backup_time, output_directory.c_str());
      _backup_time += backup_interval;
    }

  } while (!time_controller.is_end());

  printf("Writing maximum inundated depth of domain %d.\n", domain_id);
  raster_writer.write(h_max, "h_max", t_all, output_directory.c_str());

}

int run_mgpus(const char* work_dir){

  printf("Welcome using HiPIMs, now enjoy the power of multiple GPUs!\n");

  if(cd(work_dir) == -1){
    printf("The working directory does not exist!/n");
  }

 //---------------------
  std::ifstream times_setuo_file("times_setup.dat");
  if (!times_setuo_file) {
    std::cout << "Please input current time, total time, output time interval and backup interval" << std::endl;
    std::cin >> t_current >> t_all >> dt_out >> backup_interval;
  }
  else {
    Scalar _time;
    std::vector<Scalar> GPU_Time_Values;
    while (times_setuo_file >> _time) {
      GPU_Time_Values.push_back(_time);
    }
    t_current = GPU_Time_Values[0];
    t_all = GPU_Time_Values[1];
    dt_out = GPU_Time_Values[2];
    backup_interval = GPU_Time_Values[3];
    std::cout << "Current time: " << t_current << "s" << std::endl;
    std::cout << "Total time: " << t_all << "s" << std::endl;
    std::cout << "Output time interval: " << dt_out << "s" << std::endl;
    std::cout << "Backup interval: " << backup_interval << "s" << std::endl;
  }
  //---------------------

  while(t_out < t_current){
    t_out += dt_out;
  }

  while(backup_time < t_current){
    backup_time += backup_interval;
  }

  int dev_count;
  cudaGetDeviceCount(&dev_count);

  std::vector<int> device_list;

  std::ifstream device_setup_file("device_setup.dat");
  int device_id;
  if (device_setup_file.is_open()){
    while (device_setup_file >> device_id){
      device_list.push_back(device_id);
    }
  }
  else{
    printf("device_setup.dat is not found!");
  }

  device_setup_file.close();

  cuDataBank bank("halo.dat", device_list);

  spinning_barrier barrier(bank.domains_size());

  std::vector <std::thread> my_threads;
  for (unsigned int i = 0; i < bank.domains_size(); i++){
    my_threads.push_back(std::thread(single_run, std::ref(bank), device_list, i, std::ref(barrier)));
  }

  for (unsigned int i = 0; i < bank.domains_size(); i++){
    my_threads[i].join();
  }

  printf("Simulation successfully finished!\n");

  return 0;

}