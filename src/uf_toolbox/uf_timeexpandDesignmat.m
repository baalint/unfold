function [EEG] = uf_timeexpandDesignmat(EEG,varargin)
%Timeexpand Designmatrix. 
% This function takes the designmatrix% (saved in EEG.unfold.X, a
% EEG.points times nPredictor matrix) and expands it 
% over time (in the range of the windowlength).
%
%Arguments:
%  cfg.method(string): default 'stick'; Three methods are available:
%
%        * 'stick'      We shift the signal over each point in time, uses the stickfunction basis
%        * 'splines'    We use cubic splines (number = Timeexpandparam) to approximate the signal. This makes use of neighbouring timepoints that are very likely correlated.
%        * 'fourier'    We use a fourier set (up to the first Timeexpandparam frequencies) to model the signal.
%
%  cfg.timelimits (2 integer):     defines over what time the timeexpand should go, this is
%       analog to the epoch-size. This should be as long, as you think
%       overlap can happen in your data (in seconds)
%
%  cfg.timeexpandparam (integer):    depending on whether cfg.method is splines or fourier defines how
%       many splines or fourier frequencies (in case of fourier, the
%       effective parametersize is twice as large due to the sin/cos 'duplication') should be used
%       to convolve. In case of 'full', the parameter is not used.
%
%Returns:
%   * EEG.unfold.Xdc - the designmatrix for all time points
%   * EEG.unfold.timebasis - the basis set for splines / fourier. This is used later to recover the values in the time-domain, not the basis-function domain
%   * EEG.unfold.basisTime - the time of the unfold-window in seconds
%   * EEG.Xdc_terms2cols - A unique specifier defining which of the deconvolution-additional-columns belongs to which predictor
%
%*Example:*
%       EEG = uf_timeexpandDesignmat(EEG,'method','splines','windowlength',128,'timeexpandparam',30)

fprintf('\nuf_timeexpandDesignmat(): Timeexpanding the designmatrix...\n');

cfg = finputcheck(varargin,...
    { 'method',         'string' ,  {'full','splines','spline','fourier','stick'}, 'stick';
    'timelimits','integer',[],[];...
    'timeexpandparam', 'integer', [], 30;...
    'sparse','boolean',[],1;...
    },'mode','ignore');
if(ischar(cfg)); error(cfg);end

if strcmp(cfg.method,'spline')
    warning('you used method=spline, but it is method=splines')
    cfg.method = 'splines';
end
if strcmp(cfg.method,'full')
    warning('the method full is deprevated, we renamed it to stick')
    cfg.method = 'stick';
end


assert(cfg.timelimits(1)<cfg.timelimits(2),'Timelimits are not ordered correctly or are equal')
% assert(~any(isnan(EEG.unfold.X(:))),'Warning NAN values found in designmatrix. will not continue')


% Taken and modified from the epoch-eeglab function
%%cfg.timelimits(2) = cfg.timelimits(2) - 1/EEG.srate;
%  cfg.reallims(1:2) = nan;
cfg.reallims(1) = round(cfg.timelimits(1)*EEG.srate); % in samples
cfg.reallims(2) = round(cfg.timelimits(2)*EEG.srate-1);
% We use round to be sure to get an integer. Sometimes there are floating
% point problems.
cfg.windowlength = diff(cfg.reallims)+1;



cfg.windowtimes = linspace(cfg.reallims(1),cfg.reallims(2),cfg.windowlength)/EEG.srate;

assert(cfg.windowlength>0,'Your window length is 0. Did you specify timelimits correctly and is  EEG.srate set correctly?')
if cfg.windowlength>10000
    warning('are you sure you want to have an epoch the size of: %f samples, or did put the limits in ms instead of s?',cfg.windowlength)
    pause()
end


assert(isfield(EEG,'unfold'),'Could not find the unfold field: EEG.unfold')
assert(isfield(EEG.unfold,'X'),'Could not find the designmatrix: EEG.unfold.X')

% empty out the EEG.unfold field

rmList = {'beta','beta_dc','beta_nodc','beta_dcCustomrow'};
rmList = rmList(ismember(rmList,fieldnames(EEG.unfold)));
EEG.unfold = rmfield(EEG.unfold,rmList);


% this generates the stick-matrix
assert(EEG.pnts ~= 0,'Error: EEG.pnts is 0')
eventvec = zeros(size(EEG.unfold.X,2),EEG.pnts);
for e = 1:length(EEG.event)
    
    % This is needed for multiple event support. Multiple events can arrise
    % at the same latency. They would overwrite if we do not specify which
    % columns to copy over.
    ty = EEG.event(e).type;
    evtIx = find(cellfun(@(dcTy)any(strcmp(dcTy,ty)),EEG.unfold.eventtypes));
    if isempty(evtIx)
        % Trigger is not in design
        continue
    end
    s = ismember(EEG.unfold.cols2eventtypes,evtIx);
    
    % Copy over the correct columns at the right time
    eventvec(s,round(EEG.event(e).latency)) = EEG.unfold.X(e,s);
    
    
end
% defining eventvec directly as a sparse matrix is very slow.
% usually eventvec will not be so large to not do it this way. The
% convolution makes it big
if cfg.sparse
    %error('not fully implemented yet!')
    %eventvec = sparse(eventvec);
end




switch cfg.method
    case 'stick'
        
        n_entries = sum(eventvec ~= 0,2);
        
        n_cols = sum(n_entries) * cfg.windowlength;

        indcol_all = nan(1,n_cols);
        indrow_all = nan(1,n_cols);
        val_all = nan(1,n_cols);
        
        shiftvec = [1:cfg.windowlength] + cfg.timelimits(1)*EEG.srate -1;

        ixlist = cumsum(n_entries)*cfg.windowlength;
        for l = 1:size(eventvec,1) %for each predictor
            if l == 1
                startix = 1;
            else
                startix = ixlist(l-1)+1;
            end
            endix = ixlist(l);
            
            
            % column index
            tmp = repmat(1:cfg.windowlength,n_entries(l),1);
            indcol_all(startix:endix) = tmp(:)' ;
            if l >1
                indcol_all(startix:endix)  = indcol_all(startix:endix)  + indcol_all(startix-1);
            end
            
            
            
            %row index
            rowix =find(eventvec(l,:) ~= 0);

            tmp = repmat(rowix,cfg.windowlength,1)';
            
            % shift up / down according to the cfg.windowlength location
            tmp = bsxfun(@plus,tmp,shiftvec);
           
            indrow_all(startix:endix) = tmp(:)' ;

            % values

            tmp = repmat(eventvec(l,rowix),cfg.windowlength,1)';
            val_all(startix:endix) = tmp(:)';
        end

        
        
        % delete everything larger than what its supposed to be
        dimFullX = [size(eventvec,2),cfg.windowlength*size(eventvec,1)];
        % We need to make sure the dimFullX are integers
        dimFullX = round(dimFullX);
        removeIdx = indrow_all>dimFullX(1) | indrow_all<=0;
        Xdc = sparse(round(indrow_all(~removeIdx)),round(indcol_all(~removeIdx)),val_all(~removeIdx),dimFullX(1),dimFullX(2));
        if cfg.sparse ==0
           fprintf('Converting sparse Xdc to full Xdc as requested\n')
           Xdc = full(Xdc);
        end
        basis = eye(cfg.windowlength);


    case {'splines', 'fourier'}
        switch cfg.method
            case 'splines'

                if cfg.timeexpandparam > cfg.windowlength
                    warning('Spline: Your timeexpandparam is larger than the maximum (%i, max %i). Lower it (or in crease epoch length) to get rid of this warning',cfg.timeexpandparam,cfg.windowlength)
                    cfg.timeexpandparam = cfg.windowlength;
                end
                if cfg.timeexpandparam < 3
                    error('You need at least three splines (timeexpandparam & windowlength have to be >2)')
                end
                knots = linspace(1,cfg.windowlength,cfg.timeexpandparam-2);
                knots = [repmat(knots(1),1,3) knots repmat(knots(end),1,3)];
                basis = Bernstein(1:cfg.windowlength,knots,[],4)'; % 4 is the order
                basis(end,end) = 1; % there seems to be a bug in the above function. The last entry should be 1 and not 0
                
                %%
                % We could use symmetric splines, generated for example by this script.
                % Problematic is, that the toolbox would return epochs that are larger than
                % what was required. But even now, there will be border effects because
                % less samples influences the beta at the edges.
                
                %                 spl_pnts = 3; %spline size in samples
                %                 a = [ones(spl_pnts,1)]';
                %
                %                 b = conv(a,a);
                %                 c = conv(b,a);
                %                 d = conv(c,a);
                %                 figure,plot(a./max(a)),hold all,plot(b./max(b)),plot(c./max(c)),plot(d./max(d))
                %
                %                 midpoint = spl_pnts*2-1;
                %
                %% this needs the spline toolbox of matlab.
                %                 basis2 = Create_splines_linspace(cfg.windowlength-1,cfg.timeexpandparam-2,0)'; % minus two because the function adds two by default
                %                 basis2(1,:) = [];
            case 'fourier'
                % due to the cos/sin duplication it is easier to think of
                % this parameter as half of what it actually is. Thus we
                % fix it here
                cfg.timeexpandparam = 2*cfg.timeexpandparam;
                
                dF = 1/(cfg.windowlength/EEG.srate); % 1 / T
                fprintf('frequency resolution 1/T = %.2f Hz \n',dF)
                
                basis = fft(eye(cfg.windowlength)); % complex basisset
                basisSin = imag(basis);
                basisCos = real(basis);
                
                
                if cfg.timeexpandparam > cfg.windowlength
                    fprintf('timeexpandparam (%i) is too large, choosing full fourier set (%i params) \n',cfg.timeexpandparam,cfg.windowlength)
                    cfg.timeexpandparam = cfg.windowlength;
                end
                
                if (cfg.windowlength ~= cfg.timeexpandparam) && (mod(cfg.timeexpandparam,2)==0)
                    fprintf('rounding timeexpandparam from even %i to odd %i \n',cfg.timeexpandparam,cfg.timeexpandparam-1)
                    cfg.timeexpandparam = cfg.timeexpandparam-1;
                end
                
                fprintf('Fourier basisfunctions: using DC + the lower frequencies up to %.2f Hz (approximation) \n',floor((cfg.timeexpandparam)/2) * dF)
                
                basis = zeros(cfg.timeexpandparam,cfg.windowlength);
                
                % note that because we use the first cosine-basis which is
                % the intercept/DC-offset we start at 1 / 2 for cos/sin
                % The second thing to note is the ceil/floor, this is due
                % to uneven windowlength requiring to take one more basis
                % function from the cos, but not the sin
                basis([1 2:2:end],:) = basisCos(1:ceil((cfg.timeexpandparam+1)/2),:);
                basis(3:2:end,:) = basisSin(2:floor((cfg.timeexpandparam+1)/2),:);
                
                % The full fourier set would look like ths:
                %   maxCos = ceil((cfg.windowlength+1)/2);
                %   maxSin = floor((cfg.windowlength+1)/2);
                %   basis = [basisCos(1:maxCos,:);
                %   basisSin(2:maxSin,:) ];
        end
        
        if cfg.sparse
            val_all  = [];
            indcol_all = [];
            indrow_all = [];
            %Xdc = sparse(size(basis,1)*size(eventvec,1),size(eventvec,2));
        else % nonsparse
            Xdc = zeros(size(eventvec,2),size(basis,1)*size(eventvec,1));
        end
        
        
        % convolution is inherently symmetric, thus if you want the
        % 'epoch' from -1 to 1, one doesn't need to change anything
        % here. But if we want -0.1 to 1.9, then we need to move
        % the convolved vector by a certain amount of the
        % windowsize
        
        timeexpand = -round( (cfg.timelimits(1)  + cfg.timelimits(2))/2*EEG.srate); %round for float to int conversion
        
        % for each predictor
        for l = 1:size(eventvec,1)
            fprintf('Convolving and adding row %i from %i to designmatrix \n',l,size(eventvec,1))
            % we do it line by line per basis function
            for e= 1:size(basis,1)
                
                % depending on where the epoch windows are relative to 0
                % (see comment above) we have to shift accordingly
                tmpconv = conv(eventvec(l,:),basis(e,:),'same');
                if timeexpand <0
                    ts = abs(timeexpand);
                    % shift the convolution backwards
                    
                    tmpconv = [zeros(1,ts),tmpconv(1:(end-ts))];
                elseif timeexpand >0
                    ts = abs(timeexpand);
                    % shift the convolution forward
                    
                    tmpconv = [tmpconv(ts+1:end),zeros(1,ts)];
                end
                
                if cfg.sparse
                    idx = tmpconv~=0;
                    
                    indcol = repmat(e+(l-1)*size(basis,1),1,sum(idx));
                    indrow = 1:length(tmpconv);
                    indrow = indrow(idx);
                    
                    indcol_all = [indcol_all indcol];
                    indrow_all = [indrow_all indrow];
                    val_all = [val_all tmpconv(idx)];
                    %Xdc(:,) = conv(eventvec(l,:),basis(e,:),'same');
                else
                    
                    Xdc(:,e+(l-1)*size(basis,1)) = tmpconv;
                    
                end
            end
            
            
            
            
        end
        if cfg.sparse
            Xdc = sparse(indrow_all,indcol_all,val_all,size(eventvec,2),size(basis,1)*size(eventvec,1));
        end
        
        
        
end




EEG.unfold.Xdc = Xdc;
EEG.unfold.timebasis = basis;
EEG.unfold.times = cfg.windowtimes; % in s, this is different to eeglab, but makes more sense
EEG.unfold.Xdc_terms2cols = sort(repmat(1:length(EEG.unfold.colnames),1,size(EEG.unfold.timebasis,1)));
fprintf('...done\n')
end