function result = ex18_module_transfer_spectrum(probe_in, probe_out, varargin)
%ex18_module_transfer_spectrum  Compute module transfer function H(f) = Y(f)/X(f)
%
%   Inputs:
%     probe_in  - input probe data (at module input)
%     probe_out - output probe data (at module output)
%
%   Name-Value options:
%     'ModuleName', ''        - module name for plot titles
%     'FreqHz', []             - frequency axis (auto-detect if empty)
%     'StepCount', []          - number of frequency steps
%     'PRIS', 1e-6             - PRI duration in seconds
%     'FsHz', 1e9              - sample rate
%     'SaveFig', false         - save figures
%     'OutputDir', 'results'   - output directory
%     'Visible', 'on'          - figure visibility
%
%   Output:
%     result.freq_hz   - frequency axis
%     result.gain_db   - gain in dB = 20*log10(|H|)
%     result.phase_rad - phase in radians
%     result.complex_h - complex transfer function

p = inputParser;
p.addParameter('ModuleName', '');
p.addParameter('FreqHz', []);
p.addParameter('StepCount', []);
p.addParameter('PRIS', 1e-6);
p.addParameter('FsHz', 1e9);
p.addParameter('SaveFig', false);
p.addParameter('OutputDir', 'results');
p.addParameter('Visible', 'on');
p.parse(varargin{:});
opts = p.Results;

% -- Resolve frequency axis --
freq_hz = opts.FreqHz;
step_count = opts.StepCount;
pri_s = opts.PRIS;
fs_hz = opts.FsHz;

if isempty(freq_hz) && evalin('base', 'exist(''sfw_freq_hz'', ''var'')')
    freq_hz = evalin('base', 'sfw_freq_hz');
    step_count = numel(freq_hz);
elseif isempty(freq_hz)
    step_count = max(1, round(step_count));
    freq_hz = (0:step_count - 1).' * 0.5e6 + 20e6;
end

% -- Step spectrum for input and output --
spec_in = ex18_step_spectrum_probe(probe_in, freq_hz, step_count, pri_s, fs_hz);
spec_out = ex18_step_spectrum_probe(probe_out, freq_hz, step_count, pri_s, fs_hz);

% -- Compute transfer function --
valid = spec_in.valid & spec_out.valid & ...
    (abs(spec_in.complex_response) > 1e-12);

complex_h = complex(nan(size(freq_hz)));
complex_h(valid) = spec_out.complex_response(valid) ./ spec_in.complex_response(valid);

gain_db = 20 * log10(max(abs(complex_h), eps));
phase_rad = angle(complex_h);

% -- Build output --
result = struct();
result.freq_hz = freq_hz(:);
result.gain_db = gain_db(:);
result.phase_rad = phase_rad(:);
result.complex_h = complex_h(:);
result.valid = valid(:);
result.module_name = opts.ModuleName;

% -- Plot --
if nargout == 0 || opts.SaveFig
    plot_transfer(result, opts);
end
end

function plot_transfer(result, opts)
module_name = opts.ModuleName;
if isempty(module_name)
    module_name = 'Module';
end

f_mhz = result.freq_hz / 1e6;

fig = figure('Name', ['Transfer: ' module_name], ...
    'Visible', opts.Visible, 'Color', 'w', ...
    'Position', [100 100 900 700]);

% Gain
subplot(2, 1, 1);
plot(f_mhz, result.gain_db, 'b-', 'LineWidth', 1.2);
grid on;
xlabel('Frequency (MHz)');
ylabel('Gain (dB)');
title(sprintf('%s Transfer Function: Gain', module_name));
hold on;
plot(f_mhz(result.valid), result.gain_db(result.valid), 'b.');
if any(~result.valid)
    plot(f_mhz(~result.valid), result.gain_db(~result.valid), 'rx', ...
        'MarkerSize', 6);
end

% Phase
subplot(2, 1, 2);
plot(f_mhz, result.phase_rad * 180 / pi, 'r-', 'LineWidth', 1.2);
grid on;
xlabel('Frequency (MHz)');
ylabel('Phase (deg)');
title(sprintf('%s Transfer Function: Phase', module_name));
hold on;
plot(f_mhz(result.valid), result.phase_rad(result.valid) * 180 / pi, 'r.');

if opts.SaveFig
    if exist(opts.OutputDir, 'dir') ~= 7
        mkdir(opts.OutputDir);
    end
    safe_name = regexprep(module_name, '[^\w]', '_');
    fname = fullfile(opts.OutputDir, ...
        sprintf('transfer_%s.png', safe_name));
    try
        exportgraphics(fig, fname, 'Resolution', 150);
    catch
        saveas(fig, fname);
    end
    fprintf('Saved: %s\n', fname);
end

if strcmpi(opts.Visible, 'off')
    close(fig);
end
end
