classdef OutputError
properties
    % Core properties
    f 
    h
    x0
    t
    u
    z
    w
    
    % Jacobians (optional)
    df_dx
    dh_dx
    df_dzeta
    dh_dzeta
    
    % output -> state mapping matrix; x = Ay
    A
    
    zeta_p
    Sigma_p
    
    zeta_history
    J_history
    
    zeta_names
    output_names
    
    % figures
    fig1
    fig2
    fig3

end
    
methods (Access = public)
    function obj = OutputError(f, h, x0, t, u, z, w)
        % Inputs for oe = OutputError(f, h, x0, t, u, z, w)
        %
        % f(x,u,theta,w) : Dynamic state equation (Nd,1)
        % h(x,u,theta,w) : Output state equation (No,1)
        % x0 :             Initial state (Nd,1)
        % t :              Vector of sampling times (Ns,1)
        % u :              Vector of control inputs (Nc,Ns)
        % z :              Measured output state data (No,Ns)
        % w :              Auxiliary measured data (Na,1)
        %
        % Main usage:
        % - Call oe.estimate_parameters(zeta0) to iteratively compute
        %   parameter estimates. A plot will be updated as this progresses.
        %
        % Additional options:
        % 1. Use oe = oe.set_jacobians(df_dx, dh_dx, df_dzeta, dh_dzeta) to
        %    allow initial parameter estimates to be computed more
        %    accurately and to allow the use of analytical derivatives.
        % 2. Use oe = oe.set_output_to_state_matrix(A) to define the
        %    transformation x=Ay for initial parameter estimation.
        % 3. Use oe = oe.set_parameter_names(names) to allow the progress
        %    plot to label each subplot appropriately.
        
        assert(length(t) == length(u));
        assert(length(t) == length(z));
        
        obj.f = f;
        obj.h = h;
        obj.x0 = x0;
        obj.t = t;
        obj.u = u;
        obj.z = z;
        obj.w = w;
    end
    
    function [obj] = set_jacobians(obj, df_dx, dh_dx, df_dzeta, dh_dzeta)        
        obj.df_dx = df_dx;
        obj.dh_dx = dh_dx;
        obj.df_dzeta = df_dzeta;
        obj.dh_dzeta = dh_dzeta;
    end
    
    function [obj] = set_output_to_state_matrix(obj, A)
        % x = Ay
        % allows initial parameter estimates to be less important
        % if full rank, then initial parameter estimates can be anything
        
        assert(all(size(A) == [length(obj.x0), size(obj.z,1)]), ...
               'Given A inconsistent for x=Ay');
        
        obj.A = A;
    end
    
    function obj = set_known_parameter_estimates(obj, zeta_p, sigma_zeta_p)
        % zeta_p       : Vector of parameter estimates (Np,1)
        % sigma_zeta_p : Vector of estimated covariances for the parameters
        %                (Np,1)
        
        assert(length(zeta_p) == length(sigma_zeta_p));
        
        obj.zeta_p = zeta_p;
        obj.Sigma_p = diag(sigma_zeta_p);
    end
    
    function [zeta,M,R] = estimate_parameters(obj, zeta0)
        % zeta0 : Initial estimate of the parameters (Np,1)
        
        obj.fig1 = figure('Name', 'Parameter Estimates', ...
            'Position', [0 0 800 800]);
        obj.fig2 = figure('Name', 'Model Performance', ...
            'Position', [800 400 700 400]);
        obj.fig3 = figure('Name', 'Model Performance', ...
            'Position', [800 50 700 250]);
                
        % stopping criteria parameters
        stop.zeta = 1e-5;
        stop.J = 0.001;
        stop.g = 0.05;
        stop.R = 0.05;
        
        obj.zeta_history = zeta0;
        
        is_converged = false;
        zeta = zeta0;
        outer_count = 0;
                
        while (is_converged == false)
            % 1.
            % use the current parameter estimate to generate the output states
            if (outer_count == 0)
                Y = obj.compute_output_sequence(zeta);
            end
        
            % 2.
            % compute the measurement noise covariance matrix
            % ensure that is diagonal to enforce the assumption of uncorrelated
            % noise
            if (outer_count == 0)
                R = obj.compute_measurement_noise_covariance_matrix(Y);
            end
        
            % 3.
            % iteratively update the parameters using output sensitivities
            % approximate the output sensitivies (i.e., the output-parameter
            % Jacobian) using finite centred-differences
            % stop once the relative change is sufficiently small
            if (outer_count == 0)
                J = obj.compute_cost_function(R, Y, zeta);
                obj.J_history = J;
            end
            prev.R = R;
            prev.J = J;
            prev.zeta = zeta;
                                    
            inner_count = 0;
            no_cost_decrease_count = 0;
            while (inner_count == 0 || any(abs(zeta - prev.zeta) > stop.zeta))
                tic
                % approximate output sensivities 
                if outer_count == 0 && inner_count == 0 && obj.have_output_to_state_matrix()
                    dy_dzeta = obj.compute_initial_output_sensitivity(zeta, 'analytical');
                elseif outer_count == 0 && inner_count < 5 && obj.have_jacobians()
                    dy_dzeta = obj.compute_output_sensitivity(zeta, 'analytical');
                else
                    dy_dzeta = obj.compute_output_sensitivity(zeta, 'numerical');
                end
                
                % update the parameter estimates
                M = zeros(length(zeta), length(zeta));
                g = zeros(length(zeta), 1);
                for i=1:length(obj.t)
                    dy_dzeta_i = dy_dzeta(:,:,i);
                    % Fisher information matrix (approx.)
                    M = M + dy_dzeta_i' * (R \ dy_dzeta_i);
                    % log-likelihood cost function derivative
                    % -dJ(theta)/dtheta_j
                    g = g - dy_dzeta_i' * (R \ (obj.z(:,i) - Y(:,i)));
                end
                % use known parameter estimates for a Bayes-like
                % estimation, if available
                if obj.have_parameter_estimates()
                    % Sigma_p is diagonal by construction, so taking an
                    % explicit inverse is fine
                    D_zeta = -pinv(M + inv(obj.Sigma_p)) * (g + obj.Sigma_p \ (zeta - obj.zeta_p));
                else
                    D_zeta = -pinv(M) * g;
                end
                
                % track previous values for stopping criteria
                prev.zeta = zeta;
                
                % apply the update
                zeta = prev.zeta + D_zeta;
                
                % check for steps that are too large and increase the
                % cost function
                step_refinement_count = 0;
                while true
                    % update the sequence of predicted states
                    Y = obj.compute_output_sequence(zeta);

                    % store the objective function value
                    J_new = obj.compute_cost_function(R, Y, zeta);
                    
                    % if the cost function increased, go back and halve the
                    % step
                    if J_new > obj.J_history(end)
                        zeta = prev.zeta + D_zeta / (2^(step_refinement_count+1));
                    else
                        no_cost_decrease_count = 0;
                        break;
                    end
                    step_refinement_count = step_refinement_count + 1;
                    
                    if step_refinement_count == 10
                        fprintf('WARNING: No step found to decrease cost function (%i/%i)\n', ...
                            no_cost_decrease_count+1, step_refinement_count);
                        no_cost_decrease_count = no_cost_decrease_count + 1;
                        break
                    end
                end
                
                if no_cost_decrease_count == 10
                    fprintf('Possible solution found\n');
                    return;
                end
                
                % track value histories for plotting
                obj.J_history = [obj.J_history; J_new];
                obj.zeta_history = [obj.zeta_history, zeta];
                
                % check for NaN or Inf
                if any(isnan(zeta)) || any(isinf(zeta))
                    error('NaN/Inf detected');
                end
                
                % plot progress
                if ~isvalid(obj.fig1)
                    obj.fig1 = figure('Name', 'Parameter Estimates', ...
                        'Position', [0 0 800 800]);
                end
                for i=1:length(zeta)
                    n = ceil(sqrt(length(zeta)));
                    m = ceil(length(zeta) / n);
                    ax = subplot(m, n, i, 'Parent', obj.fig1);
                    cla(ax);
                    plot(ax, obj.zeta_history(i,:), 'k-o');
                    grid(ax,'on');
                    if (~isempty(obj.zeta_names))
                        title(ax, obj.zeta_names{i}, 'Interpreter', 'none');
                    else
                        title(ax, sprintf('\\zeta_%i', i));
                    end
                end
                drawnow;
                if ~isvalid(obj.fig2)
                    obj.fig2 = figure('Name', 'Model Performance', ...
                        'Position', [800 400 700 400]);
                end
                for i=1:size(obj.z,1)
                    n = ceil(sqrt(size(obj.z,1)));
                    m = ceil(size(obj.z,1) / n);
                    ax = subplot(m, n, i, 'Parent', obj.fig2);
                    cla(ax);
                    plot(ax, obj.t, obj.z(i,:), 'k.-');
                    hold(ax,'on');
                    grid(ax,'on');
                    plot(ax, obj.t, Y(i,:), 'LineWidth', 2);
                    if ~isempty(obj.output_names)
                        title(ax, obj.output_names{i}, 'Interpreter', 'none');
                    else
                        title(ax, sprintf('x_%i', i));
                    end
                end
                drawnow;
                if ~isvalid(obj.fig3)
                    obj.fig3 = figure('Name', 'Model Performance', ...
                        'Position', [800 50 700 250]);
                end
                ax = subplot(1,1,1, 'Parent', obj.fig3);
                cla(ax);
                semilogy(ax, obj.J_history, '-s');
                grid(ax,'on');
                title(ax, '[J(\theta)]_{R=R(i)}');
                drawnow;
                
                inner_count = inner_count + 1;
                if (inner_count > 100)
                    fprintf('WARNING: Exceeded maximum number of inner iterations\n');
                    return;
                end
%                 toc
            end
            
            % check convergence criteria
%             is_converged = (abs((J - prev.J)/prev.J) < 0.001) && ...
%                            all(abs(g) < 0.05) && ... 
%                            all(abs(diag(R) - diag(prev.R)) ./ abs(diag(prev.R)) < 0.05);
            is_converged = (abs((J - prev.J)/prev.J) < 0.001) && ...
                           all(abs(diag(R) - diag(prev.R)) ./ abs(diag(prev.R)) < 0.05);
            
            % compute the new output sequence and noise covariance
            % matrix
            Y = obj.compute_output_sequence(zeta);
            R = obj.compute_measurement_noise_covariance_matrix(Y);

            % compute the cost function for use in the stopping
            % criteria
            J = obj.compute_cost_function(R, Y, zeta);
            
            % reset the cost function history, since it is only valid for
            % constant R
            obj.J_history = J;
            
            outer_count = outer_count + 1;
            if (outer_count > 1000)
                fprintf('WARNING: Exceeded maximum number of outer iterations\n');
                return;
            end
        end
        
        close(obj.fig1);
        close(obj.fig2);
        close(obj.fig3);
        
        % Compute the final estimates of M
        M = zeros(length(zeta), length(zeta));
        dy_dzeta = obj.compute_output_sensitivity(zeta, 'numerical');
        for i=1:length(obj.t)
            dy_dzeta_i = dy_dzeta(:,:,i);
            % Fisher information matrix (approx.)
            M = M + dy_dzeta_i' * (R \ dy_dzeta_i);
        end
    end
    
    function obj = set_parameter_names(obj, names)
        obj.zeta_names = names;
    end
    
    function obj = set_output_names(obj, names)
        obj.output_names = names;
    end
end 

methods (Access = public)
    function Y = compute_output_sequence(obj,zeta)
        % zeta : Parameter estimates
        % Y : Output states, where each column is a distinct time (No,Ns)
        
        % first generate the sequence of dynamic states
        Y = zeros(size(obj.z,1), length(obj.t));
        X0 = obj.x0;
        Y(:,1) = obj.h(X0, obj.u(:,1), zeta, obj.w(:,1));
        for i=1:length(obj.t)-1
            % assume constant controls over the local domain
            fn = @(t,x) obj.f(x, obj.u(:,i), zeta, obj.w(:,i));
            [~,x] = ode45(fn, [obj.t(i), obj.t(i+1)], X0);
            % store the final state to be used as the next initial
            % condition
            x = x';
            X0 = x(:,end);
            % apply the output equation to get the output state
            Y(:,i+1) = obj.h(x(:,end), obj.u(:,i+1), zeta, obj.w(:,i+1));
        end
    end
    
    function R = compute_measurement_noise_covariance_matrix(obj,Y)
        % Y : Output state sequence (No,Ns)
        
        N = size(Y,2);
        R = zeros(size(Y,1), size(Y,1));
        for i=1:N
            nu = (obj.z(:,i) - Y(:,i));
            R = R + nu*nu';
        end
        R = R / N;
        % make the matrix diagonal since noise is assumed to be
        % uncorrelated between states
        R = diag(diag(R));
    end
    
    function dy_dzeta = compute_output_sensitivity(obj,zeta,solver_type)
        % zeta : Vector of parameters (Npx1)
        % solver_type : 'numerical' or 'analytical'

        % dimension 1: output states (y)
        % dimension 2: parameters (zeta)
        % dimension 3: times (t)
        dy_dzeta = zeros(size(obj.z,1), length(zeta), length(obj.t));
        
        for j=1:length(zeta)
            % use Jacobians if they're available
            % otherwise approximate the derivatives numerically
            if strcmp(solver_type, 'analytical')
                if ~obj.have_jacobians()
                    error('Analytical solver requires Jacobians')
                end
                %%% analytical
                % first solve for the sequence of states, x
                X = zeros(length(obj.x0), length(obj.t));
                X(:,1) = obj.x0;
                for i=1:length(obj.t)-1
                    % assume constant controls over the local domain
                    fn = @(t,x) obj.f(x, obj.u(:,i), zeta, obj.w(:,i));
                    [~,x] = ode45(fn, [obj.t(i), obj.t(i+1)], X(:,i));
                    x = x';
                    X(:,i+1) = x(:,end);
                end
                
                % then solve for the sequence of Jacobian values
                % i.e., state sensitivities
                % dx_dzeta_j
                dx_dzeta_j = zeros(length(obj.x0), length(zeta));
                % also compute the output sensitivity at the same time
                dy_dzeta_j = zeros(size(obj.z,1), length(zeta));
                dy_dzeta_j(:,1) = subsref(obj.dh_dzeta(obj.x0, obj.u(:,1), zeta, obj.w(:,i)), ...
                    struct('type','()','subs',{{':',j}}));
                % NB: The initial condition is 0
                for i=1:length(obj.t)-1
                    % in this function x is dx_dzeta_j(t)
                    fn = @(t,x) obj.df_dx(X(:,i), obj.u(:,i), zeta, obj.w(:,i)) * x + ...
                        subsref(obj.df_dzeta(X(:,i), obj.u(:,i), zeta, obj.w(:,i)), ...
                            struct('type','()','subs',{{':',j}}));
                    [~,x] = ode45(fn, [obj.t(i), obj.t(i+1)], dx_dzeta_j(:,i));
                    x = x';
                    dx_dzeta_j(:,i+1) = x(:,end);
                    
                    % compute the output sensitivity
                    dy_dzeta_j(:,i+1) = obj.dh_dx(X(:,i+1), obj.u(:,i+1), zeta, obj.w(:,i+1)) * dx_dzeta_j(:,i+1) + ...
                                subsref(obj.dh_dzeta(X(:,i+1), obj.u(:,i+1), zeta, obj.w(:,i+1)), ...
                                    struct('type','()','subs',{{':',j}}));
                end
            elseif strcmp(solver_type, 'numerical')
                %%% numerical
                d_zeta = zeros(length(zeta), 1);
                if zeta(j) == 0
                    d_zeta(j) = 1e-6;
                else
                    d_zeta(j) = 1e-3 * abs(zeta(j));
                end
                Y1 = obj.compute_output_sequence(zeta + d_zeta);
                Y0 = obj.compute_output_sequence(zeta - d_zeta);
                dy_dzeta_j = (Y1 - Y0) ./ (2 * abs(d_zeta(j)));
            else
                error('Unknown solver type specified: ''%s''', solver_type);
            end
            
            % reshape to match the dimensions list at the top of the
            % function
            dy_dzeta(:,j,:) = reshape(dy_dzeta_j, size(obj.z,1), 1, []);
        end
    end
    
    
    function dy_dzeta = compute_initial_output_sensitivity(obj,zeta,solver_type)
        % zeta : Vector of parameters (Npx1)
        % solver_type : 'numerical' or 'analytical'
        %
        % should only be called on the first iteration
        % provides a quick way to approach the correct parameters (zeta)
        % using measured values, as specified by obj.A
     
        % dimension 1: output states (y)
        % dimension 2: parameters (zeta)
        % dimension 3: times (t)
        dy_dzeta = zeros(size(obj.z,1), length(zeta), length(obj.t));
        
        for j=1:length(zeta)
            % use Jacobians if they're available
            % otherwise approximate the derivatives numerically
            if strcmp(solver_type, 'analytical')
                if ~obj.have_jacobians()
                    error('Analytical solver requires Jacobians')
                end
                %%% analytical
                % first solve for the sequence of states, x
                X = obj.A * obj.z;
                num_zero_rows = sum(all(obj.A == 0, 2));
                if num_zero_rows > 0
                    % only solve for states that aren't measured
                    % i.e., zero rows in A such that Ay=x
                    % track the indices that have zero rows
                    idx = 1:length(obj.x0);
                    idx = idx(all(obj.A == 0, 2));
                    X(idx,1) = obj.x0(idx);
                    for i=1:length(obj.t)-1
                        % assume constant controls over the local domain
                        fn = @(t,x) obj.f(x, obj.u(:,i), zeta, obj.w(:,i));
                        [~,x] = ode45(fn, [obj.t(i), obj.t(i+1)], X(:,i));
                        x = x';
                        X(idx,i+1) = x(idx,end);
                    end
                end
                
                % then solve for the sequence of Jacobian values
                % i.e., state sensitivities
                % dx_dzeta_j
                dx_dzeta_j = zeros(length(obj.x0), length(zeta));
                % also compute the output sensitivity at the same time
                dy_dzeta_j = zeros(size(obj.z,1), length(zeta));
                dy_dzeta_j(:,1) = subsref(obj.dh_dzeta(obj.x0, obj.u(:,1), zeta, obj.w(:,1)), ...
                    struct('type','()','subs',{{':',j}}));
                % NB: The initial condition is 0
                for i=1:length(obj.t)-1
                    % in this function x is dx_dzeta_j(t)
                    fn = @(t,x) obj.df_dx(X(:,i), obj.u(:,i), zeta, obj.w(:,i)) * x + ...
                        subsref(obj.df_dzeta(X(:,i), obj.u(:,i), zeta, obj.w(:,i)), ...
                            struct('type','()','subs',{{':',j}}));
                    [~,x] = ode45(fn, [obj.t(i), obj.t(i+1)], dx_dzeta_j(:,i));
                    x = x';
                    dx_dzeta_j(:,i+1) = x(:,end);
                    
                    % compute the output sensitivity
                    dy_dzeta_j(:,i+1) = obj.dh_dx(X(:,i+1), obj.u(:,i+1), zeta, obj.w(:,i+1)) * dx_dzeta_j(:,i+1) + ...
                                subsref(obj.dh_dzeta(X(:,i+1), obj.u(:,i+1), zeta, obj.w(:,i+1)), ...
                                    struct('type','()','subs',{{':',j}}));
                end
            elseif strcmp(solver_type, 'numerical')
                %%% numerical
                d_zeta = zeros(length(zeta), 1);
                if zeta(j) == 0
                    d_zeta(j) = 1e-6;
                else
                    d_zeta(j) = 1e-3 * abs(zeta(j));
                end
                Y1 = obj.compute_output_sequence(zeta + d_zeta);
                Y0 = obj.compute_output_sequence(zeta - d_zeta);
                dy_dzeta_j = (Y1 - Y0) ./ (2 * abs(d_zeta(j)));
            else
                error('Unknown solver type specified: ''%s''', solver_type);
            end
            
            % reshape to match the dimensions list at the top of the
            % function
            dy_dzeta(:,j,:) = reshape(dy_dzeta_j, size(obj.z,1), 1, []);
        end
    end
    
    
    function J = compute_cost_function(obj,R,Y,zeta)
        J = 0;
        for i=1:length(obj.t)
            nu = obj.z(:,i) - Y(:,i);
            J = J + nu' * (R \ nu);
        end
        J = J / 2;
        % if the Bayes-like estimation is used, alter the cost function
        if obj.have_parameter_estimates()
            v = zeta - obj.zeta_p;
            J = J + 0.5 * v' * (obj.Sigma_p \ v);
        end
    end
    
    function b = have_jacobians(obj)
        b = ~isempty(obj.df_dx) && ~isempty(obj.dh_dx) && ...
            ~isempty(obj.df_dzeta) && ~isempty(obj.dh_dzeta);
    end
    
    function b = have_output_to_state_matrix(obj)
        b = ~isempty(obj.A);
    end
    
    function b = have_parameter_estimates(obj)
        b = ~isempty(obj.zeta_p) && ~isempty(obj.Sigma_p);
    end
end
end