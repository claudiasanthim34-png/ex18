function [num, den] = ex18_design_fir_bandpass(order, passband_hz, fs_hz, error_id)
%EX18_DESIGN_FIR_BANDPASS Window-method FIR bandpass filter design.
nyquist_hz = fs_hz / 2;
passband_hz = passband_hz(:).';
if numel(passband_hz) ~= 2 || passband_hz(1) <= 0 || ...
        passband_hz(2) <= passband_hz(1) || passband_hz(2) >= nyquist_hz
    error(error_id, 'Bandpass edges must satisfy 0 < f1 < f2 < Nyquist.');
end
order = max(2, round(order));
if mod(order, 2) ~= 0, order = order + 1; end
n = -order/2:order/2;
f1 = passband_hz(1) / fs_hz;
f2 = passband_hz(2) / fs_hz;
num = 2*f2*sinc(2*f2*n) - 2*f1*sinc(2*f1*n);
window = 0.54 - 0.46*cos(2*pi*(0:order)/order);
num = num .* window;
center_hz = mean(passband_hz);
gain = abs(sum(num .* exp(-1i*2*pi*center_hz/fs_hz*(0:order))));
if gain > 0, num = num / gain; end
den = 1;
end
