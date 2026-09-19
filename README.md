# Run Planner

Plan your Hades II run, then play it in-game.

Run Planner is the game companion to the
[Run Planner application](https://github.com/maybe-adamant/RunPlanner).
Build your route in the app, choose your rewards and upgrades, and send the
plan to the mod. It then guides the game's rooms, rewards, and offers to match
what you planned. You still play the run and make the planned choices.

## How to use

1. Download Run Planner from the
   [planner releases](https://github.com/maybe-adamant/RunPlanner/releases),
   extract the portable ZIP, and open **RunPlanner.exe**.
2. Install this mod in your Hades II mod-manager profile.
3. Create or load a plan in the app, configure your loadout and route, and
   fix any issues shown by the planner.
4. Open **File → Publish to Game**, choose your game profile, and pick one of
   the six plan slots.
5. Launch the game with that profile. In Run Planner's in-game settings,
   select the published slot as your active plan.
6. Start a new run with the loadout you planned and follow its choices.

For more about the application and its source, visit the
[planner repository](https://github.com/maybe-adamant/RunPlanner).

You can keep up to six plans ready to play. Changing the active slot during a
run only changes which plan will be used for the next run; it does not replace
the plan already in progress.

### Plan in the app

Create an **Underworld**, **Surface**, or **Dream Dive** project—or load an
existing plan.

![New project screen with Underworld, Surface, Dream Dive, and Load options](https://raw.githubusercontent.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/main/docs/images/planner-new-project.webp)

Choose your starting weapon, Arcana, Fear, keepsake, and reward in **Loadout**.

![Underworld loadout with Argent Skull, Aspect of Persephone, Jeweled Pom, and a Zeus starting reward](https://raw.githubusercontent.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/main/docs/images/planner-loadout.webp)

Select a room and open **Room Timeline** to configure its planned interactions.

![Erebus opening-room timeline with the planned Zeus boon pickup](https://raw.githubusercontent.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/main/docs/images/planner-timeline.webp)

Open **Edit Trait** to configure the offered boons and the one you intend to pick.

![Zeus trait offer with Epic Heaven Strike selected and no current findings](https://raw.githubusercontent.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/main/docs/images/planner-trait-offer.webp)

### Publish to the game

Once your plan is ready, open **File → Publish to Game**.

![File menu with Publish to Game highlighted](https://raw.githubusercontent.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/main/docs/images/planner-publish-menu.webp)

Choose the mod-manager profile containing Run Planner, select a plan slot,
and click **Publish**. The screenshots use the author's profile, **h2-dev**;
choose the profile you play with.

![Publish to game dialog showing profile and plan-slot selection](https://raw.githubusercontent.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/main/docs/images/planner-publish-slot.webp)

### Inspect before starting

Select the slot you published to and click **Inspect / Reload Selected Plan** to check its
loadout. **Inactive | Steering: off** is expected before starting a run.

![Plan inspection before a run, showing the selected slot, weapon, keepsake, and Arcana](https://raw.githubusercontent.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/main/docs/images/plan-inspection.webp)

## While playing

Open the in-game inspector's **Plan** tab to preview the selected slot's
loadout and planned keepsake changes. **Current Run** shows the plan being
played, room progress, and details if something goes wrong. Sync and
steering status stay visible in either tab.

**Synchronized | Steering: active** means the mod is following your plan.

![A synchronized run with steering active](https://raw.githubusercontent.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/main/docs/images/run-synchronized.webp)

Follow the rooms and choices you planned in the app. If the run no longer
matches the plan, the mod reports the mismatch and stops steering. Normal
gameplay continues—you can keep playing or start a fresh planned run.

**Desynchronized | Steering: off** means the run no longer matches the plan.
Open **Current Run** to see what went wrong.

![A desynchronized run with steering stopped and the failed checkpoint displayed](https://raw.githubusercontent.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/main/docs/images/run-desynchronized.webp)

## Beta and feedback

Run Planner is in beta. You may encounter bugs or differences between your
plan and the game.

If something goes wrong, [report an issue](https://github.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/issues)
with your plan, the room where it happened, what you expected, and what you
actually saw. Include `logOutput.log` from your profile's `ReturnOfModding`
folder when possible.

To find the log when using r2modman:

1. Open File Explorer and paste this into the address bar, then press Enter:

   ```text
   %USERPROFILE%\AppData\Roaming\r2modmanPlus-local\HadesII\profiles\
   ```

2. Open the folder matching the profile you play with (for example, `h2-dev`).
3. Open its `ReturnOfModding` folder.
4. Attach `logOutput.log` to your issue report.

Interested in the code? See the
[development guide](https://github.com/h2pack-runplanner/adamantRunPlanner-Run_Planner/blob/main/CONTRIBUTING.md).
