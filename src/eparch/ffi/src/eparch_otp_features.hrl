-ifndef(EPARCH_OTP_FEATURES_HRL).
-define(EPARCH_OTP_FEATURES_HRL, true).

%% Execute an expression only when the current runtime exports the OTP
%% function that implements it. The compiler accepts calls to functions that
%% do not exist in the OTP release used to build eparch, so this explicit
%% capability check turns a late `undef` into a stable, descriptive failure.
-define(OTP_FEATURE(RequiredOtp, Module, Function, Arity, Expression), begin
    case eparch_otp_features:available(Module, Function, Arity) of
        true ->
            Expression;
        false ->
            eparch_otp_features:unsupported(RequiredOtp, Module, Function, Arity)
    end
end).

-endif.
