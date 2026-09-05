// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Superficie MINIMA de pons v2 que RobinShare necesita, transcrita de la fuente
///         VERIFICADA en Blockscout (chainId 4663). No se copia el protocolo entero: solo lo
///         que se llama, para que el ABI sea auditable de un vistazo.

/// @notice Ledger pull-payment de pons. Verificado, NO es proxy, no tiene owner ni claimFor.
/// @dev `claim()` es ESTRICTAMENTE msg.sender: nadie puede cobrar en nombre de otro. Por eso el
///      vault tiene que llamarlo el mismo. Paga con `.call{value:}` reenviando TODO el gas (sin
///      stipend de 2300), asi que el receptor necesita un `receive()` payable o revierte
///      `TransferFailed()`. Si el saldo es cero revierte `NoBalance()` (0xc2caa2a6) — por eso
///      siempre se consulta `balanceOf` antes de llamar.
interface IV2FeeEscrow {
    function claim() external returns (uint256 amount);
    function claimToken(address token) external returns (uint256 amount);
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

/// @notice La curva de bonding de un launch pre-graduacion.
/// @dev OJO con el nombre: el campo `deployer` de la curva NO es quien lanzo — es el
///      **creatorFeeRecipient vigente**. La fuente lo dice ("Token creator, credited as the
///      creator fee recipient"), `setCreatorFeeRecipient` lo muta, y `_creditQuote(deployer, ...)`
///      acredita ahi. Por eso NUESTRO vault, siendo el recipient, esta autorizado a barrer.
interface IPonsV2Curve {
    function sweepFees(uint256 minBuybackTokensOut) external;
    function deployer() external view returns (address);
    function graduated() external view returns (bool);
    /// @dev Solo lo usa el fork test, para tradear de verdad contra la curva real. Con par nativo
    ///      `msg.value` debe igualar a `quoteIn`, o la curva revierte `NativeValueMismatch`.
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        returns (uint256 quoteOut);
    /// @dev Umbral cruzado. Solo lo usa el fork test para llevar una curva real a graduar.
    function readyToGraduate() external view returns (bool);
}

/// @notice Registro de launches del factory de pons v2.
interface IPonsV2LaunchFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase; // enum GraduationPhase
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

// ─────────────────────── entrypoint de launch (solo lo usan tests y scripts) ───────────────────

/// @notice Metadata social del token, transcrita de `PonsV2LauncherToken.Socials`.
/// @dev Es referencia off-chain: no confiere ningun privilegio sobre el token.
struct PonsSocials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

/// @notice Parametros de `launchToken`, transcritos de `PonsV2LaunchFactory.TokenParams`.
/// @dev La forma esta VERIFICADA por selector, no por lectura:
///        launchToken((string,string,string,string,(string,string,string,string,string),
///                     address,uint16,bool,bytes32,bytes32),uint256,address) = 0xf35abbcf
///        ...la misma con `address[] snipeTaxExemptions`                     = 0xa72101af
///      Ambos coinciden con los selectores del spec §16, o sea que el orden y los tipos de los
///      campos son exactamente los del contrato desplegado.
struct PonsTokenParams {
    string name;
    string symbol;
    string logo;
    string description;
    PonsSocials socials;
    /// @notice A donde van las creator fees. `address(0)` = el que lanza. Para RobinShare va el vault.
    address creatorFeeRecipient;
    /// @notice Tax extra del creador sobre el fee base, tope `maxCreatorTaxBps` (hoy 1000 = 10%).
    uint16 creatorTaxBps;
    /// @notice RobinShare lo fija SIEMPRE en false: con buyback activo `buybackBurnBps` se lleva
    ///         la mitad del bucket del creador y la vestea 5 anios.
    bool buybackEnabled;
    /// @notice Pin opcional de la economia cotizada. 0 = sin chequeo.
    /// @dev Se obtiene con `previewLaunchEconomics(launchConfigId, pairToken)`. Sin esto, un
    ///      re-peg del owner de pons puede aterrizar debajo de un launch en vuelo.
    bytes32 expectedEconomics;
    /// @notice Salt CREATE2 del par curva+token. Namespaced por cuenta: basta que no se repita
    ///         entre los launches de la misma wallet.
    bytes32 salt;
}

/// @notice Superficie de launch del factory de pons v2.
interface IPonsV2Launchpad {
    function launchToken(PonsTokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);

    function previewLaunchEconomics(uint256 launchConfigId, address pairToken)
        external
        view
        returns (bytes32);

    function launchFee() external view returns (uint256);
    function maxCreatorTaxBps() external view returns (uint256);
    function launchConfigCount() external view returns (uint256);
    function launchEnabled() external view returns (bool);
    function canLaunch(address launcher) external view returns (bool);
    function approvedPairTokens(address pairToken) external view returns (bool);
    /// @dev Dispara la graduacion una vez cruzado el umbral. Permissionless en pons.
    function graduate(address token) external;
}
