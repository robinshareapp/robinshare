// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// Shim local: los vendored de Flap importan la variante "upgradeable" de OZ v4.
// En OZ v5 (que usamos) la interfaz es la misma IAccessControl no-upgradeable.
// Este alias evita instalar openzeppelin-contracts-upgradeable solo para un import
// que nuestros contratos NO usan (solo aparece en el interface combinado IPortal,
// del cual nosotros consumimos unicamente IPortalTypes).
import {IAccessControl} from "openzeppelin-contracts/access/IAccessControl.sol";

interface IAccessControlUpgradeable is IAccessControl {}
