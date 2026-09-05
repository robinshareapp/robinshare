// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RobinShareVault} from "./RobinShareVault.sol";

/// @title RobinShareVaultFactory — despliega y registra los vaults del rail pons
/// @notice Permissionless: cualquiera crea un vault para cualquier identidad. Eso es el producto,
///         no un bug — lanzar una moneda "para" un dev que no la pidio es el caso de uso.
///
/// @dev PORT desde el rail de Flap. El entrypoint viejo (`newVault`, gateado al VaultPortal, con
///      un blob `vaultData` opaco) no tiene equivalente en pons: el launchpad nunca llama a una
///      factory de vaults de terceros. Acá el vault se crea PRIMERO, con parametros tipados, y
///      recien despues se lanza el token apuntandole las creator fees.
contract RobinShareVaultFactory {
    uint8 public constant TYPE_WALLET = 0;
    uint8 public constant TYPE_GITHUB = 1;
    uint8 public constant TYPE_TWITTER = 2;

    /// @notice Piso del plazo de recovery. 0 sigue significando NUNCA (el default del producto).
    /// @dev Sin piso, un plazo corto deja al launcher recuperar el balance antes de que la persona
    ///      real tenga chance razonable de reclamarlo.
    uint256 public constant MIN_RECOVERY_DAYS = 30;
    uint256 public constant MAX_RECOVERY_DAYS = 3650;

    address public immutable feeEscrow;
    address public immutable ponsFactory;
    address public immutable xVerifier;

    /// @notice El attester vigente de la ruta GitHub. Los vaults lo leen EN VIVO de aca.
    /// @dev Rotable por el attester vigente o por `attesterAdmin` (co-gate de emergencia).
    address public attester;

    /// @notice Co-gate de EMERGENCIA cuya UNICA funcion es rotar el attester. `address(0)` lo
    ///         desactiva.
    ///
    /// @dev ⚠️ LEER ANTES DE ELEGIR ESTA DIRECCION. Una version anterior de este comentario decia
    ///      que "quien lo tenga no puede sacar un wei". **Es falso**, y dos revisores externos lo
    ///      reprodujeron con un PoC: rotar el attester a una llave propia y firmarse un voucher
    ///      alcanza los fondos de CUALQUIER vault de GitHub, porque en esa ruta "probar la
    ///      identidad" ES la firma del attester. Probado en
    ///      `ReviewRound2.t.sol::test_attesterAdmin_SI_alcanzaLosFondosDeUnVaultGithub`.
    ///
    ///      Lo que si es cierto, y es el limite real de la potestad:
    ///        · no alcanza los vaults de wallet (ahi `boundWallet` lo fija el constructor);
    ///        · no alcanza los vaults de X (esos dependen del XGeneralVerifier, no del attester);
    ///        · no puede hacerlo en silencio: rotar emite `AttesterRotated` y el bind emite `Bound`.
    ///
    ///      Por que existe igual: el audit v3 del rail Flap habia cerrado esto como High
    ///      (finding 5) con el Guardian de Flap como respaldo, y el port lo borro dejando
    ///      `rotateAttester` auto-gateado. Sin sucesor, una llave de attester perdida CONGELA para
    ///      siempre el ETH de todos los vaults de GitHub. O sea: la eleccion es entre un riesgo de
    ///      liveness (sin admin) y uno de custodia (con admin), y es de Jose — PENDIENTES.md §3.
    address public immutable attesterAdmin;

    /// @notice Registro de procedencia. Lo consulta el attester server ANTES de firmar nada.
    /// @dev Sin esto, cualquiera despliega un contrato que finge ser un vault. Es la segunda capa
    ///      del fix de la firma en blanco; la primera es que el server calcula el digest el mismo.
    mapping(address => bool) public isVault;

    mapping(bytes32 => address[]) private _vaultsByIdentity;
    address[] public allVaults;

    event VaultCreated(
        bytes32 indexed identityHash,
        uint8 identityType,
        string identityValue,
        address vault,
        address launcher,
        uint64 recoveryAfter
    );
    event AttesterRotated(address indexed oldAttester, address indexed newAttester);

    error ZeroAddress();
    error OnlyAttester();
    error BadIdentityType();
    error RecoveryWindowTooShort();
    error RecoveryWindowTooLong();
    error ValueMustBeEmptyForWallet();
    error WalletRequired();
    error BadHandleLength();
    error BadHandleCharset();

    constructor(
        address attester_,
        address feeEscrow_,
        address ponsFactory_,
        address xVerifier_,
        address attesterAdmin_
    ) {
        if (attester_ == address(0) || feeEscrow_ == address(0) || ponsFactory_ == address(0)) {
            revert ZeroAddress();
        }
        attester = attester_;
        attesterAdmin = attesterAdmin_;
        feeEscrow = feeEscrow_;
        ponsFactory = ponsFactory_;
        xVerifier = xVerifier_; // puede ser 0 si la chain no tiene verifier: los vaults X se rechazan
    }

    function rotateAttester(address newAttester) external {
        if (msg.sender != attester && (attesterAdmin == address(0) || msg.sender != attesterAdmin)) {
            revert OnlyAttester();
        }
        if (newAttester == address(0)) revert ZeroAddress();
        emit AttesterRotated(attester, newAttester);
        attester = newAttester;
    }

    /// @notice Crea un vault para una identidad. Permissionless.
    /// @param identityType_ 0 = wallet, 1 = github, 2 = twitter/X
    /// @param rawValue el handle (vacio para wallet). Se normaliza on-chain.
    /// @param identityWallet_ solo para TYPE_WALLET.
    /// @param recoveryDays 0 = NUNCA (default del producto), o >= 30 y <= 3650.
    function createVault(
        uint8 identityType_,
        string calldata rawValue,
        address identityWallet_,
        uint256 recoveryDays
    ) external returns (address vault) {
        if (identityType_ > TYPE_TWITTER) revert BadIdentityType();
        if (recoveryDays != 0 && recoveryDays < MIN_RECOVERY_DAYS) revert RecoveryWindowTooShort();
        if (recoveryDays > MAX_RECOVERY_DAYS) revert RecoveryWindowTooLong();

        uint64 recoveryAfter =
            recoveryDays == 0 ? 0 : uint64(block.timestamp + recoveryDays * 1 days);

        bytes32 identityHash;
        string memory normalized = "";
        address vaultAttesterSource = identityType_ == TYPE_GITHUB ? address(this) : address(0);
        address vaultXVerifier = identityType_ == TYPE_TWITTER ? xVerifier : address(0);

        if (identityType_ == TYPE_WALLET) {
            if (bytes(rawValue).length != 0) revert ValueMustBeEmptyForWallet();
            if (identityWallet_ == address(0)) revert WalletRequired();
            identityHash = keccak256(abi.encode(uint8(0), identityWallet_));
        } else {
            normalized = _normalize(identityType_, rawValue);
            identityHash = keccak256(abi.encode(identityType_, normalized));
        }
        // Un vault X sin verifier quedaria brickeado para siempre (xVerifier es immutable en el
        // vault y claimByProof revertiria eternamente).
        if (identityType_ == TYPE_TWITTER && vaultXVerifier == address(0)) revert ZeroAddress();

        vault = address(
            new RobinShareVault(
                msg.sender,
                identityType_,
                normalized,
                identityWallet_,
                vaultAttesterSource,
                vaultXVerifier,
                recoveryAfter,
                feeEscrow,
                ponsFactory
            )
        );

        isVault[vault] = true;
        _vaultsByIdentity[identityHash].push(vault);
        allVaults.push(vault);
        emit VaultCreated(identityHash, identityType_, normalized, vault, msg.sender, recoveryAfter);
    }

    function getVaults(bytes32 identityHash) external view returns (address[] memory) {
        return _vaultsByIdentity[identityHash];
    }

    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice El mismo hash que usa `createVault`, para que el server pueda ubicar los vaults de
    ///         una identidad sin recorrer `allVaults`.
    function identityHashFor(uint8 identityType_, string calldata rawValue, address identityWallet_)
        external
        pure
        returns (bytes32)
    {
        if (identityType_ == TYPE_WALLET) return keccak256(abi.encode(uint8(0), identityWallet_));
        return keccak256(abi.encode(identityType_, _normalize(identityType_, rawValue)));
    }

    /// @dev strip '@' inicial + lowercase ASCII + CHARSET ESTRICTO por tipo.
    ///      twitter: 1-15 de [a-z0-9_] · github: 1-39 de [a-z0-9-] SIN guion al principio, al
    ///      final, ni dos seguidos — que son exactamente las reglas de GitHub.
    ///
    ///      La regla del guion se agrego tras un review adversarial: el charset solo ya dejaba
    ///      crear vaults para `-torvalds`, `torvalds-` o `tor--valds`, que NINGUNA cuenta real de
    ///      GitHub puede tener. El attester nunca ve ese login, `claimAndBind` no puede firmar
    ///      jamas, y con `recoveryDays > 0` el clawback OPCIONAL del launcher se vuelve
    ///      GARANTIZADO. Es el mismo ataque que la validacion de charset existe para impedir
    ///      (homoglifos cirilicos, zero-width), entrando por la puerta de al lado. En X no
    ///      aplica: ahi el guion bajo si puede ir en los bordes y repetido.
    ///
    ///      RECUPERADO del contrato auditado tras un review adversarial: la primera version del
    ///      port solo bajaba a minusculas, lo que permitia crear vaults con handles que NINGUNA
    ///      persona real puede reclamar (homoglifos cirilicos, zero-width, espacios). Con un plazo
    ///      de recovery eso convierte el clawback OPCIONAL del launcher en uno GARANTIZADO: se
    ///      lanza "para" un dev, la UI muestra su handle, el claim nunca puede matchear, y a los 30
    ///      dias el launcher se lleva todo. Es exactamente el ataque que el producto existe para
    ///      impedir, reabierto por otra puerta.
    function _normalize(uint8 t, string memory raw) internal pure returns (string memory) {
        bytes memory b = bytes(raw);
        uint256 start = (b.length > 0 && b[0] == "@") ? 1 : 0;
        uint256 len = b.length - start;
        uint256 max = t == TYPE_TWITTER ? 15 : 39;
        if (len < 1 || len > max) revert BadHandleLength();
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            bytes1 c = b[start + i];
            if (c >= "A" && c <= "Z") c = bytes1(uint8(c) + 32);
            bool sep = t == TYPE_TWITTER ? c == bytes1("_") : c == bytes1("-");
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || sep;
            if (!ok) revert BadHandleCharset();
            // GitHub no admite el guion al principio, al final, ni dos seguidos.
            if (sep && t == TYPE_GITHUB) {
                if (i == 0 || i == len - 1) revert BadHandleCharset();
                if (out[i - 1] == bytes1("-")) revert BadHandleCharset();
            }
            out[i] = c;
        }
        return string(out);
    }
}
