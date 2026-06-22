addpath('D:/work place/Matlab/ex18');
model = 'ex18_sfw_top';
if bdIsLoaded(model)
    close_system(model,0);
end
load_system([model '.slx']);
% Try to set the parameters for RF_VGA
try
    set_param([model '/RF_VGA'], 'DataSource', 'Gain and noise data');
    set_param([model '/RF_VGA'], 'Gain', 'rf_vga_gain_db');
    fprintf('Set RF_VGA to Gain and noise data\n');
catch ME
    fprintf('Error setting RF_VGA: %s\n', ME.message);
end
try
    set_param([model '/RF_PA'], 'DataSource', 'Gain and noise data');
    set_param([model '/RF_PA'], 'Gain', 'rf_pa_gain_db');
    fprintf('Set RF_PA to Gain and noise data\n');
catch ME
    fprintf('Error setting RF_PA: %s\n', ME.message);
end
save_system([model '.slx']);
fprintf('Done.\n');