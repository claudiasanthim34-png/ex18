function [num, den] = ex18_design_fir_lowpass(order, cutoff_hz, fs_hz)
%EX18_DESIGN_FIR_LOWPASS Window-method FIR lowpass filter design.
nyquist_hz = fs_hz / 2;
if cutoff_hz <= 0 || cutoff_hz >= nyquist_hz
    error('ex18:BadLPFCutoff', 'Lowpass cutoff must satisfy 0 < f < Nyquist.');
end
order = max(2, round(order));
if mod(order, 2) ~= 0, order = order + 1; end
n = -order/2:order/2;
fc = cutoff_hz / fs_hz;
num = 2*fc*sinc(2*fc*n);
window = 0.54 - 0.46*cos(2*pi*(0:order)/order);
num = num .* window;
g0 = abs(sum(num));
if g0 > 0, num = num / g0; end
den = 1;
end
