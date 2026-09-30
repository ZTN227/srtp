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
fc = signal_center_frequency(s.sig);
assert(fc > 0 && fc < s.fs/2, 'Bellhop centre frequency must be below Nyquist.');
[SSP, Bdry, Pos, Beam, cInt, RMax, c] = ...
    build_ssp(s.z, s.temp, s.salt, s.sd, s.rd, s.rr);  %构建 Bellhop 所需全套环境参数
%计算声速剖面 SSP、海面海底边界、射线参数、最大计算距离、各深度对应的声速
env = fullfile(channelDir, [s.id '.env']);
arr = fullfile(channelDir, [s.id '.arr']);
write_env(env, 'BELLHOP', s.id, fc, SSP, Bdry, Pos, Beam, cInt, RMax);
old = pwd;
restoreFolder = onCleanup(@() cd(old));
cd(channelDir);
bellhop(s.id);
assert(isfile(arr), 'Bellhop did not generate %s.', arr);
[Arr, ~] = read_arrivals_local(arr, 500);  %读取 arr 到达文件，解析多途射线：每一条到达路径的到达延迟、幅度、相位
[tx, label, source] = generate_signal(s.sig, s.fs, s.dur);  %生成信号
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
meta.ssp = struct('depth_m', s.z(:).', 'temperature_c', s.temp(:).', ...
'salinity_psu', s.salt(:).', 'sound_speed_mps', c(:).');
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
