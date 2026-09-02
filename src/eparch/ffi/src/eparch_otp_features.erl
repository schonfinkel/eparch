-module(eparch_otp_features).
-moduledoc """
Runtime capability checks used by eparch's OTP feature gate macro.
""".

-include("eparch_otp_features.hrl").

-export([available/3, unsupported/4]).

-doc "Return whether the current runtime exports an OTP function.".
-spec available(module(), atom(), arity()) -> boolean().
available(Module, Function, Arity) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> erlang:function_exported(Module, Function, Arity);
        {error, _Reason} -> false
    end.

-doc "Raise the stable error used when an OTP capability is unavailable.".
-spec unsupported(string(), module(), atom(), arity()) -> no_return().
unsupported(RequiredOtp, Module, Function, Arity) ->
    erlang:error(
        {
            unsupported_otp_feature,
            Module,
            Function,
            Arity,
            RequiredOtp,
            erlang:system_info(otp_release)
        }
    ).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

available_feature_test() ->
    ?assertEqual(self(), ?OTP_FEATURE("pre-OTP", erlang, self, 0, erlang:self())).

unavailable_feature_test() ->
    CurrentOtp = erlang:system_info(otp_release),
    ?assertError(
        {unsupported_otp_feature, erlang, eparch_missing_feature, 0, "99.0", CurrentOtp},
        ?OTP_FEATURE("99.0", erlang, eparch_missing_feature, 0, erlang:eparch_missing_feature())
    ).

unavailable_module_test() ->
    CurrentOtp = erlang:system_info(otp_release),
    ?assertError(
        {
            unsupported_otp_feature,
            eparch_missing_otp_module,
            missing,
            0,
            "99.0",
            CurrentOtp
        },
        ?OTP_FEATURE(
            "99.0",
            eparch_missing_otp_module,
            missing,
            0,
            eparch_missing_otp_module:missing()
        )
    ).
-endif.
