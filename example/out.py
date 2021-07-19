
import os

from pypims import flood
from pypims import IO

from pypims.IO.demo_functions import get_sample_data
import matplotlib.pyplot as plt

print("!!!")
data_path, _ = get_sample_data()  # get the path of sample data
case_folder = os.path.join(os.getcwd(), 'model_case')  # define a case folder in the current directory
print(case_folder)
num_of_devices = 1
print(data_path)
obj_in = IO.InputHipims(dem_data=data_path, case_folder=case_folder, num_of_sections=num_of_devices)  # create input object
case_output = IO.OutputHipims(input_obj = obj_in)

gauges_pos, times, values = case_output.read_gauges_file(file_tag = 'h')

lines = plt.plot(times, values)
plt.xlabel('time (s)')
plt.ylabel('depth (m)')
plt.legend(lines[:2],['downstream','upstream'])
plt.show() #for control
fig_path = f'{case_folder}/fin.png'
print(fig_path)
plt.savefig(fig_path)

max_depth = case_output.read_grid_file(file_tag='h_max_3600')
max_depth.mapshow()
fig_path2 = f'{case_folder}/fin2.png'
plt.savefig(fig_path2)

