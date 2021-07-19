import os


from pypims import IO
from pypims.IO.demo_functions import get_sample_data
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import random

print("!!!")
data_path, _ = get_sample_data()  # get the path of sample data
case_folder = os.path.join(os.getcwd(), 'model_case')  # define a case folder in the current directory
print(case_folder)
num_of_devices = 1

data_folder_path = os.path.dirname(os.path.abspath(data_path))


# init object

case_input = IO.InputHipims(dem_data=data_path, case_folder=case_folder,
                            num_of_sections=num_of_devices)  # create input object
case_input.set_initial_condition('h0', 0.0)

# read data
rain_source = pd.read_csv(os.path.join(data_folder_path, 'rain_source.csv'), header=None)
rain_source.head()

rain_mask = IO.Raster(os.path.join(data_folder_path,'rain_mask.gz'))

landcover = IO.Raster(os.path.join(data_folder_path, 'landcover.gz'))
landcover.mapshow()

# init boundary

box_upstream = np.array([[1427, 195],  # bottom left
                         [1446, 243]])  # upper right
box_downstream = np.array([[58, 1645],  # upper left
                           [72, 1170]])  # bottom right
discharge_values = np.array([[0, 100],  # first column: time - s; second colum: discharge - m3/s
                             [3600, 100]])

bound_list = [
    {'polyPoints': box_upstream,
     'type': 'open',
     'hU': discharge_values},
    {'polyPoints': box_downstream,
     'type': 'open',
     'h': np.array([[0, 12.5],
                    [3600, 12.5]])}]  # we fix the downstream depth as 12.5 m

case_input.set_boundary_condition(boundary_list=bound_list)
case_input.domain_show()  # show domain map
map_path = f'{case_folder}/domain_map.png'
plt.savefig(map_path)

# init rain

rain_source_np = rain_source.to_numpy()
case_input.set_rainfall(rain_mask=rain_mask, rain_source=rain_source_np)

# int land cover

case_input.set_landcover(landcover)
case_input.set_grid_parameter(manning={'param_value': [0.035, 0.055],
                                       'land_value': [0, 1],
                                       'default_value': 0.035})

# init gauges

case_input.set_gauges_position(np.array([[560, 1030],
                                         [1140, 330]]))

# set runtime  and write
case_input.set_runtime([0, 7200, 900, 1800])

print(case_input)
case_input.write_input_files()  # create all input files