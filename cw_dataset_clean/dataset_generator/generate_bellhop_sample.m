function meta = generate_bellhop_sample(s, dataRoot, datasetName)
audioDir = fullfile(dataRoot, 'audio');
specDir = fullfile(dataRoot, 'spectrogram');
metaDir = fullfile(dataRoot, 'metadata');
channelDir = fullfile(dataRoot, 'channel');
dirs = {audioDir, specDir, metaDir, channelDir};
for k = 1:numel(dirs)
    if ~exist(dirs{k}, 'dir'), mkdir(dirs{k});
    end
end

%% ============ 新增：读取WOA23实测剖面，只改这里，不碰write_env ============
woa_lat = -76.5;
woa_lon = -177.5;
[z_meas, temp_meas, salt_meas, c_meas] = load_woa23_profile(woa_lat, woa_lon);

fc = signal_center_frequency(s.sig);
assert(fc > 0 && fc < s.fs/2, 'Bellhop centre frequency must be below Nyquist.');

% 重点：build_ssp输入替换为WOA数组，s.sd/s.rd/s.rr保留参数集里面的收发深度距离
[SSP, Bdry, Pos, Beam, cInt, RMax, c] = ...
    build_ssp(z_meas, temp_meas, salt_meas, s.sd, s.rd, s.rr);

env = fullfile(channelDir, [s.id '.env']);
arr = fullfile(channelDir, [s.id '.arr']);

% ========= 原生write_env调用，【完全不改动这一行，入参原样保留！！】 =========
write_env(env, 'BELLHOP', s.id, fc, SSP, Bdry, Pos, Beam, cInt, RMax);

old = pwd;
restoreFolder = onCleanup(@() cd(old));
cd(channelDir);
bellhop(s.id);
assert(isfile(arr), 'Bellhop did not generate %s.', arr);
[Arr, ~] = read_arrivals_local(arr, 500);

[tx, label, source] = generate_signal(s.sig, s.fs, s.dur);
[clean, delayS, amp] = delayandsum(tx, s.fs, Arr, 1, 1, 1);

%% =====================【内嵌实测噪声代码，强制列向量，防止内存爆炸】=====================
fs = s.fs;
dur = s.dur;
root = fileparts(mfilename('fullpath'));
noiseDir = fullfile(root, 'noise_library');
wavList = dir(fullfile(noiseDir, '*.wav'));
idx_rand = randi(length(wavList));
filePath = fullfile(noiseDir, wavList(idx_rand).name);
[waveRaw, fs_src] = audioread(filePath);
%转单通道，强制转为【列向量】
if size(waveRaw,2) > 1
    waveRaw = waveRaw(:,1);
end
waveRaw = waveRaw(:);
%重采样 interp1，不需要DSP工具箱
if fs_src ~= fs
    t_old = (0:length(waveRaw)-1)/fs_src;
    t_new = linspace(0, t_old(end), round(length(waveRaw)*fs/fs_src));
    waveRaw = interp1(t_old, waveRaw, t_new, 'linear','extrap');
end
waveRaw = waveRaw(:); %再次强制列向量
N_target = round(fs * dur);
L_raw = length(waveRaw);
if L_raw >= N_target
    startPos = randi(L_raw - N_target + 1);
    noise = waveRaw(startPos : startPos + N_target -1);
else
    noise = repmat(waveRaw, ceil(N_target / L_raw), 1);
    noise = noise(1:N_target);
end
noise = noise(:); % 强制列向量！！！关键，防止行向量
%随机相位翻转
if rand < 0.5
    noise = -noise;
end
%小幅增益扰动 0.8~1.2倍
gainRand = 0.8 + 0.4*rand();
noise = noise * gainRand;
noise = noise(:);
%SNR缩放（使用clean，原纯净接收信号）
sig_power = mean(clean.^2);
noise_power_raw = mean(noise.^2);
snr_linear = 10^(s.snr_db / 10);
noise = noise * sqrt(sig_power / (snr_linear * noise_power_raw));
noise = noise(:);
% 【最关键：把noise裁剪/补齐到和clean完全一样长度！！】
N_clean = length(clean);
if length(noise) > N_clean
    noise = noise(1:N_clean);
elseif length(noise) < N_clean
    noise = repmat(noise, ceil(N_clean/length(noise)), 1);
    noise = noise(1:N_clean);
end
noise = noise(:);
rx = clean + noise;
%% =========================================================================
actualSnrDb = 10*log10(mean(clean.^2) / mean((rx-clean).^2));
if max(abs(rx)) > 0.999, rx = 0.999*rx/max(abs(rx)); end
wav = fullfile(audioDir, [s.id '.wav']);
png = fullfile(specDir, [s.id '.png']);
json = fullfile(metaDir, [s.id '.json']);
audiowrite(wav, rx, s.fs, 'BitsPerSample', 16);
figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 900 450]);
spectrogram(rx, hann(512, 'periodic'), 448, 1024, s.fs, 'yaxis');
ylim([0 s.fs/2]/1000); colorbar;
title(sprintf('%s: %.0f Hz, %.1f dB SNR', label, fc, actualSnrDb));
xlabel('Time (s)'); ylabel('Frequency (kHz)');
exportgraphics(gcf, png, 'Resolution', 160);
close(gcf);

meta.id = s.id;
meta.label = label;
meta.audio_path = relPath(datasetName, 'audio', [s.id '.wav']);
meta.spectrogram_path = relPath(datasetName, 'spectrogram', [s.id '.png']);
meta.metadata_path = relPath(datasetName, 'metadata', [s.id '.json']);
meta.sample_rate_hz = s.fs;
meta.duration_s = s.dur;
meta.source = source;

% =====元数据Ssp部分，改用WOA输出数组，不再使用s的虚拟剖面=====
meta.ssp = struct('depth_m', z_meas(:).', ...
    'temperature_c', temp_meas(:).', ...
    'salinity_psu', salt_meas(:).', ...
    'sound_speed_mps', c_meas(:).', ...
    'source', 'WOA23_september');

meta.channel = struct('simulator', 'Bellhop', ...
'env_path', relPath(datasetName, 'channel', [s.id '.env']), ...
'arr_path', relPath(datasetName, 'channel', [s.id '.arr']), ...
'source_depth_m', s.sd, 'receiver_depth_m', s.rd, 'range_km', s.rr, ...
'bellhop_frequency_hz', fc, 'multipath_count', numel(delayS), ...
'path_delay_s', delayS(:).', 'path_amplitude_real', real(amp(:)).', ...
'path_amplitude_imag', imag(amp(:)).');
meta.receiver = struct('noise_type', 'real_measured_noise_random', ...
'target_snr_db', s.snr_db, ...
'actual_snr_db', actualSnrDb);
writeText(json, jsonencode(meta));
end

function path = relPath(datasetName, folder, file)
path = fullfile('output', 'datasets', datasetName, folder, file);
end
function writeText(path, text)
fid = fopen(path, 'w');
assert(fid ~= -1, 'Cannot write %s.', path);
closer = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', text);
end
