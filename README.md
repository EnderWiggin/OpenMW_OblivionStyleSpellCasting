# Oblivion-Style Spell Casting (OSSC) v1.2

**Oblivion-Style Spell Casting** (OSSC) brings modern spellcasting mechanics to OpenMW. It allows you to cast your currently selected spell or power using a dedicated hotkey without needing to switch to spell stance, just like in TES IV: Oblivion.

## 1. Features
- **Dedicated Casting Key:** Quickly cast any spell with a single button (Unset by default, make sure to set it in the settings). Gamepad compatible!
- **High-Fidelity Animations:** Uses custom animations for target/touch and self that blend seamlessly with your movement.
- **Physics-Based Projectiles:** Spells are launched as actual world objects via the `Magicka Expanded` framework, supporting collision, momentum, and custom gravity/physics.
- **School-Specific Speeds:** Configure the velocity of Fire, Frost, Shock, and other magic schools independently in the settings (they are set to default vanilla values by default).

---

## 2. Requirements
To run OSSC, the following mods must be enabled:
1. **Magicka Expanded Framework:** The underlying engine used for spell launching and impact logic.
2. **MaxYari Lua Physics:** Required for Magicka Expanded Framework to work properly.

---

## 3. Usage & Keybindings
- **Cast Key:** Press your assigned key to cast the currently selected spell.
- **Rebinding:** You can change the casting key in the **ESC > Options > Scripts > Oblivion-Style Spell Casting** menu. Click on the "Quick Cast" binding and press any key to reassign it.
- **Projectile Speeds:** You can adjust how fast spells fly for every magic school manually in the settings menu.

---

## 4. Technical Details
OSSC is designed to be lightweight. It handles the player's input and animation state, then delegates the heavy lifting (VFX resolution, physics processing, and impact application) to the **Magicka Expanded Framework**. This ensures maximum compatibility with other mods that use the same framework.

---

## 5. Credits
- **Mod Author:** skrow42 / Antigravity
- **Animations:** BIG thanks to MaxYari and dubiousnpc for providing the animations for casting. Also Fallchildren for his VFX Bone file for the spell effects on hands
- **Physics Engine:** Thanks to MaxYari again for his great physics engine
